#!/usr/bin/env python3
"""Bind backup, WORM, alert and isolated-PITR evidence into durable receipts.

This root-only command emits (1) a detailed acceptance receipt and (2) the
narrow database ``backup`` receipt consumed by the activation recovery helper.
The narrow receipt's evidenceReference contains the fixed detailed path and its
SHA-256.  No receipt is emitted unless every independent evidence input passes.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _fixed_sibling(module_name: str, filename: str):
    sibling = Path(__file__).resolve(strict=True).with_name(filename)
    specification = importlib.util.spec_from_file_location(module_name, sibling)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load fixed {module_name} sibling")
    module = importlib.util.module_from_spec(specification)
    sys.modules[module_name] = module
    specification.loader.exec_module(module)
    return module


try:
    from backup_alert import AlertError, validate_event, validate_receipt
except ModuleNotFoundError as exc:
    if exc.name != "backup_alert":
        raise
    _alert_module = _fixed_sibling("backup_alert", "backup_alert.py")
    AlertError = _alert_module.AlertError
    validate_event = _alert_module.validate_event
    validate_receipt = _alert_module.validate_receipt

try:
    from pgbackrest_repo2 import (
        ContractError,
        _load_json,
        parse_policy,
        validate_active,
        validate_sha256,
        validate_worm_evidence,
    )
except ModuleNotFoundError as exc:
    if exc.name != "pgbackrest_repo2":
        raise
    _repo2_module = _fixed_sibling("pgbackrest_repo2", "pgbackrest_repo2.py")
    ContractError = _repo2_module.ContractError
    _load_json = _repo2_module._load_json
    parse_policy = _repo2_module.parse_policy
    validate_active = _repo2_module.validate_active
    validate_sha256 = _repo2_module.validate_sha256
    validate_worm_evidence = _repo2_module.validate_worm_evidence


CONFIRMATION = "WRITE VERIFIED UTEN BACKUP ACCEPTANCE RECEIPTS"
POLICY_PATH = Path("/etc/uten-imp-backup/repo2-policy.json")
WORM_PATH = Path("/etc/uten-imp-backup/worm-evidence.json")
ACTIVE_CONFIG_PATH = Path("/etc/pgbackrest/conf.d/20-uten-imp-repo2.conf")
ACTIVE_APPROVAL_PATH = Path("/etc/uten-imp-backup/repo2-enabled.approved")
HEALTH_PATH = Path("/var/lib/uten-imp-backup-health/health.json")
ALERT_DELIVERED_DIR = Path("/var/lib/uten-imp-backup-alerts/delivered")
ALERT_RECEIPT_DIR = Path("/var/lib/uten-imp-backup-alerts/receipts")
PITR_ACCEPTANCE_DIR = Path("/var/lib/uten-imp-backup/pitr-acceptance")
RESTORE_RECEIPT_DIR = Path("/var/lib/uten-imp-release/database-receipts")
DETAIL_DIR = Path("/var/lib/uten-imp-backup/acceptance-receipts")
NARROW_DIR = RESTORE_RECEIPT_DIR
TRUSTED_RELEASE_GUARD = Path("/usr/local/libexec/uten-imp-release/release_guard.py")
TRUSTED_RELEASE_ALLOWED_SIGNERS = Path(
    "/etc/uten-imp-release-trust/release-allowed-signers"
)
SHA256 = re.compile(r"^[0-9a-f]{64}$")
VERSION = re.compile(r"^v\d{4}\.\d{2}\.\d{2}-[1-9]\d{0,2}$")
REFERENCE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{2,127}$")
FILENAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{2,127}\.json$")
WAL = re.compile(r"^[0-9A-F]{24}$")
UTC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
MIGRATION_FILE = re.compile(r"^V([1-9]\d*)__([A-Za-z0-9_]+)\.sql$")
RESTORE_EVIDENCE = re.compile(
    r"^pgbackrest:repo=([1-2]);set=([A-Za-z0-9._-]{3,128});target=(.+)$"
)
EVIDENCE_REFERENCE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+=-]{2,511}$")
REQUIRED_BUSINESS_CHECKS = {
    "finance",
    "inventory",
    "production",
    "sales",
    "procurement",
    "audit",
    "attachments",
}


def _digest(path: Path, expected: str, label: str) -> tuple[bytes, str]:
    if not SHA256.fullmatch(expected):
        raise ContractError(f"{label} expected SHA-256 is invalid")
    raw = path.read_bytes()
    if len(raw) > 4 * 1024 * 1024:
        raise ContractError(f"{label} exceeds 4 MiB")
    actual = hashlib.sha256(raw).hexdigest()
    if actual != expected:
        raise ContractError(f"{label} differs from its approved SHA-256")
    return raw, actual


def _object(raw: bytes, label: str) -> dict[str, Any]:
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ContractError(f"{label} is not UTF-8 JSON") from exc
    if not isinstance(value, dict):
        raise ContractError(f"{label} must be one object")
    return value


def _utc(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not UTC.fullmatch(value):
        raise ContractError(f"{label} must use YYYY-MM-DDTHH:MM:SSZ")
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def _recent(value: Any, label: str, now: datetime, maximum_days: int) -> datetime:
    parsed = _utc(value, label)
    age = (now - parsed).total_seconds()
    if age < 0 or age > maximum_days * 86400:
        raise ContractError(f"{label} is outside the {maximum_days}-day acceptance window")
    return parsed


def validate_health(
    value: dict[str, Any], target_head: str, migration_count: int, now: datetime
) -> None:
    if value.get("schemaVersion") != 1 or value.get("status") != "PASS":
        raise ContractError("backup health report is not PASS schemaVersion 1")
    checked = _utc(value.get("checkedAtUtc"), "backup health checkedAtUtc")
    age = (now - checked).total_seconds()
    if age < 0 or age > 900:
        raise ContractError("backup health report is older than 15 minutes")
    if value.get("remoteImmutabilityProvenByThisCheck") is not False:
        raise ContractError("backup health must not claim provider immutability")
    if value.get("pitrRestoreDrillProvenByThisCheck") is not False:
        raise ContractError("backup health must not claim a PITR drill")
    if value.get("walInventoryContinuityProvenByThisCheck") is not False:
        raise ContractError("backup health inventory must not claim gap-free WAL continuity")
    if value.get("repositoryCheckPerformedByThisRun") is not False:
        raise ContractError("five-minute backup health must not claim a repository check")
    repositories = value.get("repositories")
    if not isinstance(repositories, list) or len(repositories) != 2:
        raise ContractError("backup health must contain repo1 and repo2")
    for expected_repo, repository in enumerate(repositories, start=1):
        if not isinstance(repository, dict) or repository.get("repo") != expected_repo:
            raise ContractError("backup health repository order/identity differs")
        points = repository.get("restorePoints")
        point_count = repository.get("successfulFullRestorePoints")
        if (
            not isinstance(points, list)
            or len(points) < 7
            or isinstance(point_count, bool)
            or not isinstance(point_count, int)
            or point_count < 7
        ):
            raise ContractError(f"repo{expected_repo} does not have seven restore points")
    identity = value.get("databaseIdentity")
    if not isinstance(identity, dict):
        raise ContractError("backup health database identity is missing")
    flyway = identity.get("flyway")
    if not isinstance(flyway, dict):
        raise ContractError("backup health Flyway identity is missing")
    if str(flyway.get("headVersion")) != target_head:
        raise ContractError("backup health Flyway head differs from the signed target")
    if flyway.get("successfulMigrationCount") != migration_count:
        raise ContractError("backup health Flyway count differs from the signed target")
    if not isinstance(flyway.get("canonicalHistorySha256"), str) or not SHA256.fullmatch(
        flyway["canonicalHistorySha256"]
    ):
        raise ContractError("backup health canonical Flyway digest is invalid")
    if not isinstance(flyway.get("signedProjectionSha256"), str) or not SHA256.fullmatch(
        flyway["signedProjectionSha256"]
    ):
        raise ContractError("backup health signed Flyway projection digest is invalid")


def _bounded_bytes(path: Path, maximum: int, label: str) -> bytes:
    with path.open("rb") as source:
        raw = source.read(maximum + 1)
    if not raw or len(raw) > maximum:
        raise ContractError(f"{label} is empty or exceeds {maximum} bytes")
    return raw


def validate_signed_flyway_rows(
    raw: bytes,
    health: dict[str, Any],
    head: str,
    migration_count: int,
) -> str:
    if raw.startswith(b"\xef\xbb\xbf"):
        raise ContractError("signed Flyway rows must not contain a UTF-8 BOM")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ContractError("signed Flyway rows are not UTF-8") from exc
    if not text.endswith("\n") or "\r" in text:
        raise ContractError("signed Flyway rows must use canonical LF lines")
    parsed: list[tuple[str, str, int]] = []
    previous = 0
    for line in text.splitlines():
        fields = line.split("\t")
        if len(fields) != 3:
            raise ContractError("signed Flyway row does not have three TSV fields")
        version, script, checksum_text = fields
        match = MIGRATION_FILE.fullmatch(script)
        if (
            not version.isdigit()
            or version != str(int(version))
            or not match
            or match.group(1) != version
            or int(version) <= previous
        ):
            raise ContractError("signed Flyway row version/script/order is not canonical")
        try:
            checksum = int(checksum_text)
        except ValueError as exc:
            raise ContractError("signed Flyway checksum is not an integer") from exc
        if checksum_text != str(checksum) or not -(2**31) <= checksum <= 2**31 - 1:
            raise ContractError("signed Flyway checksum is not a canonical int32")
        parsed.append((version, script, checksum))
        previous = int(version)
    if len(parsed) != migration_count or str(previous) != head:
        raise ContractError("signed Flyway row head/count differs from the target")
    canonical = "".join(
        f"{version}\t{script}\t{checksum}\n"
        for version, script, checksum in parsed
    ).encode("utf-8")
    if raw != canonical:
        raise ContractError("signed Flyway row bytes are not canonical")
    digest = hashlib.sha256(canonical).hexdigest()
    health_digest = health["databaseIdentity"]["flyway"]["signedProjectionSha256"]
    if digest != health_digest:
        raise ContractError(
            "live Flyway versions/scripts/checksums differ from the signed manifest"
        )
    return digest


def verify_signed_flyway(
    *,
    manifest_path: Path,
    signature_path: Path,
    expected_manifest_sha: str,
    expected_signature_sha: str,
    version: str,
    head: str,
    migration_count: int,
    migration_set_sha: str,
    health: dict[str, Any],
) -> dict[str, str]:
    manifest_raw, manifest_sha = _digest(
        manifest_path, expected_manifest_sha, "signed release manifest"
    )
    _signature_raw, signature_sha = _digest(
        signature_path, expected_signature_sha, "signed release signature"
    )
    try:
        result = subprocess.run(
            [
                "/usr/bin/python3",
                "-I",
                str(TRUSTED_RELEASE_GUARD),
                "verified-flyway-checksums",
                "--manifest",
                str(manifest_path),
                "--signature",
                str(signature_path),
                "--allowed-signers",
                str(TRUSTED_RELEASE_ALLOWED_SIGNERS),
                "--expected-version",
                version,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"},
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ContractError("root-installed release guard could not complete") from exc
    if result.returncode != 0 or len(result.stdout) > 4 * 1024 * 1024:
        raise ContractError("root-installed release guard rejected the signed Flyway inventory")
    if (
        hashlib.sha256(_bounded_bytes(manifest_path, 4 * 1024 * 1024, "signed release manifest")).hexdigest()
        != manifest_sha
        or hashlib.sha256(_bounded_bytes(signature_path, 256 * 1024, "signed release signature")).hexdigest()
        != signature_sha
    ):
        raise ContractError("signed release evidence changed during guard verification")
    manifest = _object(manifest_raw, "signed release manifest")
    flyway = manifest.get("flyway")
    if not isinstance(flyway, dict) or (
        flyway.get("headVersion") != head
        or flyway.get("migrationCount") != migration_count
        or flyway.get("migrationSetSha256") != migration_set_sha
    ):
        raise ContractError("signed release manifest Flyway target differs")
    rows_sha = validate_signed_flyway_rows(
        result.stdout, health, head, migration_count
    )
    return {
        "manifestSha256": manifest_sha,
        "signatureSha256": signature_sha,
        "flywayRowsSha256": rows_sha,
        "migrationSetSha256": migration_set_sha,
    }


def validate_restore_receipt(
    value: dict[str, Any],
    version: str,
    head: str,
    migration_set_sha: str,
    now: datetime,
) -> None:
    expected = {
        "approvalReference",
        "completedAtUtc",
        "evidenceReference",
        "flywayHeadVersion",
        "flywayMigrationSetSha256",
        "receiptType",
        "schemaVersion",
        "successful",
        "targetVersion",
    }
    if set(value) != expected:
        raise ContractError("restore receipt schema differs from recovery helper schemaVersion 1")
    if (
        value.get("schemaVersion") != 1
        or value.get("receiptType") != "restore"
        or value.get("successful") is not True
    ):
        raise ContractError("isolated PITR restore receipt is not successful")
    restore_approval = value.get("approvalReference")
    if not isinstance(restore_approval, str) or not REFERENCE.fullmatch(restore_approval):
        raise ContractError("restore receipt approval reference is not canonical")
    if (
        value.get("targetVersion") != version
        or value.get("flywayHeadVersion") != head
        or value.get("flywayMigrationSetSha256") != migration_set_sha
    ):
        raise ContractError("restore receipt signed target identity differs")
    _recent(value.get("completedAtUtc"), "restore receipt completedAtUtc", now, 31)
    if not isinstance(value.get("evidenceReference"), str) or not value["evidenceReference"]:
        raise ContractError("restore receipt evidence reference is missing")


def validate_restore_binding(
    restore_receipt: dict[str, Any], pitr_acceptance: dict[str, Any]
) -> None:
    reference = restore_receipt["evidenceReference"]
    match = RESTORE_EVIDENCE.fullmatch(reference)
    if not match or match.group(1) != "2":
        raise ContractError("restore receipt does not prove a repo2 pgBackRest restore")
    if match.group(2) != pitr_acceptance.get("backupSet"):
        raise ContractError("restore receipt backup set differs from PITR acceptance")
    if match.group(3) == "latest" or match.group(3) != pitr_acceptance.get("targetTimeUtc"):
        raise ContractError("restore receipt does not bind the accepted PITR target time")
    if _utc(
        pitr_acceptance.get("completedAtUtc"), "PITR acceptance completedAtUtc"
    ) < _utc(restore_receipt.get("completedAtUtc"), "restore receipt completedAtUtc"):
        raise ContractError("PITR acceptance predates the completed restore")


def validate_pitr_acceptance(
    value: dict[str, Any],
    health: dict[str, Any],
    restore_sha: str,
    now: datetime,
) -> None:
    expected = {
        "schemaVersion",
        "status",
        "completedAtUtc",
        "repository",
        "sourceSystemIdentifier",
        "sourceTimeline",
        "backupSet",
        "walStart",
        "walStop",
        "targetTimeUtc",
        "restoreReceiptSha256",
        "actualRtoSeconds",
        "actualRpoSeconds",
        "authorityReference",
        "acceptanceOwner",
        "secondReviewer",
        "checks",
    }
    if set(value) != expected or value.get("schemaVersion") != 1 or value.get("status") != "PASS":
        raise ContractError("PITR/business acceptance schema or status differs")
    _recent(value.get("completedAtUtc"), "PITR acceptance completedAtUtc", now, 31)
    if value.get("repository") != 2:
        raise ContractError("accepted PITR must restore from the off-site repo2")
    identity = health["databaseIdentity"]
    if value.get("sourceSystemIdentifier") != identity.get("systemIdentifier"):
        raise ContractError("PITR source system_identifier differs from current authority")
    if value.get("sourceTimeline") != identity.get("timeline"):
        raise ContractError("PITR source timeline differs from current backup authority")
    repo2 = health["repositories"][1]
    restore_points = repo2.get("restorePoints")
    if not isinstance(restore_points, list):
        raise ContractError("repo2 restore-point detail is missing")
    matching = [
        point
        for point in restore_points
        if isinstance(point, dict) and point.get("label") == value.get("backupSet")
    ]
    if len(matching) != 1:
        raise ContractError("PITR backup set is not one of repo2's accepted restore points")
    point = matching[0]
    if value.get("walStart") != point.get("walStart") or value.get("walStop") != point.get("walStop"):
        raise ContractError("PITR WAL range differs from the selected repo2 backup set")
    if not WAL.fullmatch(str(value.get("walStart", ""))) or not WAL.fullmatch(
        str(value.get("walStop", ""))
    ):
        raise ContractError("PITR WAL identity is invalid")
    target_time = _utc(value.get("targetTimeUtc"), "PITR targetTimeUtc")
    stop_epoch = point.get("stopEpoch")
    if (
        isinstance(stop_epoch, bool)
        or not isinstance(stop_epoch, int)
        or target_time.timestamp() < stop_epoch
        or target_time > now
    ):
        raise ContractError("PITR target time is outside the selected backup/current window")
    if value.get("restoreReceiptSha256") != restore_sha:
        raise ContractError("PITR acceptance does not bind the restore receipt digest")
    for label in ("actualRtoSeconds", "actualRpoSeconds"):
        item = value.get(label)
        if isinstance(item, bool) or not isinstance(item, int) or item < 0 or item > 31 * 86400:
            raise ContractError(f"PITR {label} is invalid")
    for label in ("authorityReference", "acceptanceOwner", "secondReviewer"):
        item = value.get(label)
        if not isinstance(item, str) or not EVIDENCE_REFERENCE.fullmatch(item):
            raise ContractError(f"PITR {label} is invalid")
    checks = value.get("checks")
    if not isinstance(checks, dict) or set(checks) != REQUIRED_BUSINESS_CHECKS:
        raise ContractError("PITR business check set is incomplete")
    for label, check in checks.items():
        if not isinstance(check, dict) or set(check) != {"status", "evidenceReference"}:
            raise ContractError(f"PITR {label} check schema differs")
        if check.get("status") != "PASS":
            raise ContractError(f"PITR {label} check is not PASS")
        reference = check.get("evidenceReference")
        if not isinstance(reference, str) or not EVIDENCE_REFERENCE.fullmatch(reference):
            raise ContractError(f"PITR {label} evidence reference is invalid")


def build_receipts(
    *,
    health: dict[str, Any],
    health_sha: str,
    worm_evidence: dict[str, Any],
    worm_sha: str,
    alert_event: dict[str, Any],
    alert_event_sha: str,
    alert_receipt: dict[str, Any],
    alert_receipt_sha: str,
    restore_receipt_sha: str,
    pitr_acceptance: dict[str, Any],
    pitr_acceptance_sha: str,
    active_repo2_preflight: dict[str, Any],
    signed_release_evidence: dict[str, str],
    approval: str,
    version: str,
    head: str,
    migration_count: int,
    migration_set_sha: str,
    detail_path: Path,
) -> tuple[dict[str, Any], dict[str, Any]]:
    detail = {
        "schemaVersion": 1,
        "receiptType": "backup-acceptance-detail",
        "successful": True,
        "completedAtUtc": health["checkedAtUtc"],
        "approvalReference": approval,
        "targetVersion": version,
        "flywayHeadVersion": head,
        "flywayMigrationCount": migration_count,
        "flywayMigrationSetSha256": migration_set_sha,
        "databaseIdentity": health["databaseIdentity"],
        "continuousWal": health["continuousWal"],
        "repositories": health["repositories"],
        "healthReportSha256": health_sha,
        "wormEvidence": worm_evidence,
        "wormEvidenceSha256": worm_sha,
        "activeRepo2Preflight": active_repo2_preflight,
        "signedReleaseEvidence": signed_release_evidence,
        "externalAlertEvidence": {
            "eventId": alert_event["eventId"],
            "providerMessageId": alert_receipt["providerMessageId"],
            "eventSha256": alert_event_sha,
            "receiptSha256": alert_receipt_sha,
        },
        "isolatedPitrEvidence": {
            "repository": 2,
            "backupSet": pitr_acceptance["backupSet"],
            "walStart": pitr_acceptance["walStart"],
            "walStop": pitr_acceptance["walStop"],
            "targetTimeUtc": pitr_acceptance["targetTimeUtc"],
            "actualRtoSeconds": pitr_acceptance["actualRtoSeconds"],
            "actualRpoSeconds": pitr_acceptance["actualRpoSeconds"],
            "restoreReceiptSha256": restore_receipt_sha,
            "businessAcceptanceSha256": pitr_acceptance_sha,
            "checks": pitr_acceptance["checks"],
        },
        "remoteImmutabilityVerifiedSeparately": True,
        "externalAlertDeliveryVerifiedSeparately": True,
        "isolatedRepo2PitrVerifiedSeparately": True,
    }
    detail_bytes = (json.dumps(detail, sort_keys=True, indent=2) + "\n").encode("utf-8")
    detail_sha = hashlib.sha256(detail_bytes).hexdigest()
    narrow = {
        "approvalReference": approval,
        "completedAtUtc": detail["completedAtUtc"],
        "evidenceReference": f"path={detail_path};sha256={detail_sha}",
        "flywayHeadVersion": head,
        "flywayMigrationSetSha256": migration_set_sha,
        "receiptType": "backup",
        "schemaVersion": 1,
        "successful": True,
        "targetVersion": version,
    }
    return detail, narrow


def _secure_root_file(path: Path, label: str, owner_uid: int = 0) -> None:
    info = path.lstat()
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_nlink != 1
        or info.st_uid != owner_uid
        or info.st_gid != 0
        or stat.S_IMODE(info.st_mode) != 0o600
    ):
        raise ContractError(f"{label} must be root:root 0600 with one link")


def _write_new(path: Path, value: dict[str, Any]) -> str:
    payload = (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written < 1:
                raise OSError("short receipt write")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(parent)
    finally:
        os.close(parent)
    return hashlib.sha256(payload).hexdigest()


def _write_or_verify(path: Path, value: dict[str, Any]) -> tuple[str, bool]:
    payload = (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8")
    if path.exists() or path.is_symlink():
        _secure_root_file(path, "existing acceptance receipt")
        existing = path.read_bytes()
        if existing != payload:
            raise ContractError("existing acceptance receipt bytes differ; overwrite is forbidden")
        return hashlib.sha256(existing).hexdigest(), False
    return _write_new(path, value), True


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", type=Path, default=POLICY_PATH)
    parser.add_argument("--worm-evidence", type=Path, default=WORM_PATH)
    parser.add_argument("--expected-worm-evidence-sha256", required=True)
    parser.add_argument("--health-report", type=Path, default=HEALTH_PATH)
    parser.add_argument("--expected-health-report-sha256", required=True)
    parser.add_argument("--alert-event", required=True, type=Path)
    parser.add_argument("--expected-alert-event-sha256", required=True)
    parser.add_argument("--alert-receipt", required=True, type=Path)
    parser.add_argument("--expected-alert-receipt-sha256", required=True)
    parser.add_argument("--restore-receipt", required=True, type=Path)
    parser.add_argument("--expected-restore-receipt-sha256", required=True)
    parser.add_argument("--pitr-acceptance", required=True, type=Path)
    parser.add_argument("--expected-pitr-acceptance-sha256", required=True)
    parser.add_argument("--trusted-release-manifest", required=True, type=Path)
    parser.add_argument("--expected-release-manifest-sha256", required=True)
    parser.add_argument("--trusted-release-signature", required=True, type=Path)
    parser.add_argument("--expected-release-signature-sha256", required=True)
    parser.add_argument("--approval-reference", required=True)
    parser.add_argument("--target-version", required=True)
    parser.add_argument("--flyway-head-version", required=True)
    parser.add_argument("--flyway-migration-count", required=True, type=int)
    parser.add_argument("--flyway-migration-set-sha256", required=True)
    parser.add_argument("--detail-name", required=True)
    parser.add_argument("--database-receipt-name", required=True)
    parser.add_argument("--confirm", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if os.name != "posix" or os.geteuid() != 0:
            raise ContractError("backup acceptance receipt writer requires root on POSIX")
        if args.confirm != CONFIRMATION:
            raise ContractError(f"--confirm must exactly equal: {CONFIRMATION}")
        if not REFERENCE.fullmatch(args.approval_reference):
            raise ContractError("approval reference is not canonical")
        if not VERSION.fullmatch(args.target_version):
            raise ContractError("target version must match vYYYY.MM.DD-N")
        if not args.flyway_head_version.isdigit() or args.flyway_migration_count < 1:
            raise ContractError("signed Flyway head/count is invalid")
        if not SHA256.fullmatch(args.flyway_migration_set_sha256):
            raise ContractError("signed Flyway migration-set SHA-256 is invalid")
        if not FILENAME.fullmatch(args.detail_name) or not FILENAME.fullmatch(
            args.database_receipt_name
        ):
            raise ContractError("receipt filenames are not canonical")
        if args.policy != POLICY_PATH or args.worm_evidence != WORM_PATH or args.health_report != HEALTH_PATH:
            raise ContractError("policy, WORM and health evidence paths are fixed")
        if args.alert_event.parent != ALERT_DELIVERED_DIR or args.alert_receipt.parent != ALERT_RECEIPT_DIR:
            raise ContractError("external alert evidence paths are fixed")
        if args.restore_receipt.parent != RESTORE_RECEIPT_DIR:
            raise ContractError("restore receipt path is fixed")
        if args.pitr_acceptance.parent != PITR_ACCEPTANCE_DIR:
            raise ContractError("PITR acceptance path is fixed")
        for directory in (DETAIL_DIR, NARROW_DIR):
            info = directory.lstat()
            if (
                not stat.S_ISDIR(info.st_mode)
                or info.st_uid != 0
                or info.st_gid != 0
                or stat.S_IMODE(info.st_mode) != 0o700
            ):
                raise ContractError(f"receipt directory is not root:root 0700: {directory}")
        for path, label in (
            (args.alert_event, "alert event"),
            (args.alert_receipt, "alert receipt"),
            (args.restore_receipt, "restore receipt"),
            (args.pitr_acceptance, "PITR acceptance"),
        ):
            _secure_root_file(path, label)
        import grp
        import pwd

        try:
            postgres_gid = grp.getgrnam("postgres").gr_gid
            postgres_uid = pwd.getpwnam("postgres").pw_uid
        except KeyError as exc:
            raise ContractError("postgres account/group does not exist") from exc
        policy_info = args.policy.lstat()
        if (
            not stat.S_ISREG(policy_info.st_mode)
            or policy_info.st_nlink != 1
            or policy_info.st_uid != 0
            or policy_info.st_gid != postgres_gid
            or stat.S_IMODE(policy_info.st_mode) != 0o640
        ):
            raise ContractError("runtime policy must be root:postgres 0640 with one link")
        worm_info = args.worm_evidence.lstat()
        if (
            not stat.S_ISREG(worm_info.st_mode)
            or worm_info.st_nlink != 1
            or worm_info.st_uid != 0
            or worm_info.st_gid != postgres_gid
            or stat.S_IMODE(worm_info.st_mode) != 0o640
        ):
            raise ContractError("active WORM evidence must be root:postgres 0640 with one link")
        health_info = args.health_report.lstat()
        if (
            not stat.S_ISREG(health_info.st_mode)
            or health_info.st_nlink != 1
            or health_info.st_uid != postgres_uid
            or health_info.st_gid != postgres_gid
            or stat.S_IMODE(health_info.st_mode) != 0o640
        ):
            raise ContractError("health report must be postgres:postgres 0640 with one link")

        now = datetime.now(timezone.utc)
        policy_value = _load_json(args.policy, "policy")
        policy = parse_policy(policy_value)
        validate_sha256(args.worm_evidence, args.expected_worm_evidence_sha256)
        worm_value = _load_json(args.worm_evidence, "WORM evidence")
        validate_worm_evidence(worm_value, policy, now=now)
        active_repo2_preflight = validate_active(
            args.policy,
            ACTIVE_CONFIG_PATH,
            ACTIVE_APPROVAL_PATH,
            args.worm_evidence,
            now=now,
        )
        health_raw, health_sha = _digest(
            args.health_report, args.expected_health_report_sha256, "health report"
        )
        health_value = _object(health_raw, "health report")
        validate_health(
            health_value, args.flyway_head_version, args.flyway_migration_count, now
        )
        signed_release_evidence = verify_signed_flyway(
            manifest_path=args.trusted_release_manifest,
            signature_path=args.trusted_release_signature,
            expected_manifest_sha=args.expected_release_manifest_sha256,
            expected_signature_sha=args.expected_release_signature_sha256,
            version=args.target_version,
            head=args.flyway_head_version,
            migration_count=args.flyway_migration_count,
            migration_set_sha=args.flyway_migration_set_sha256,
            health=health_value,
        )

        event_raw, event_sha = _digest(
            args.alert_event, args.expected_alert_event_sha256, "alert event"
        )
        event_value = validate_event(_object(event_raw, "alert event"))
        receipt_raw, receipt_sha = _digest(
            args.alert_receipt, args.expected_alert_receipt_sha256, "alert receipt"
        )
        receipt_value = validate_receipt(args.alert_receipt, event_value)
        if hashlib.sha256(receipt_raw).hexdigest() != receipt_sha:
            raise ContractError("alert receipt changed during validation")
        _recent(receipt_value["deliveredAtUtc"], "alert deliveredAtUtc", now, 31)

        restore_raw, restore_sha = _digest(
            args.restore_receipt, args.expected_restore_receipt_sha256, "restore receipt"
        )
        restore_value = _object(restore_raw, "restore receipt")
        validate_restore_receipt(
            restore_value,
            args.target_version,
            args.flyway_head_version,
            args.flyway_migration_set_sha256,
            now,
        )
        pitr_raw, pitr_sha = _digest(
            args.pitr_acceptance,
            args.expected_pitr_acceptance_sha256,
            "PITR acceptance",
        )
        pitr_value = _object(pitr_raw, "PITR acceptance")
        validate_pitr_acceptance(pitr_value, health_value, restore_sha, now)
        validate_restore_binding(restore_value, pitr_value)

        detail_path = DETAIL_DIR / args.detail_name
        narrow_path = NARROW_DIR / args.database_receipt_name
        detail, narrow = build_receipts(
            health=health_value,
            health_sha=health_sha,
            worm_evidence=worm_value,
            worm_sha=args.expected_worm_evidence_sha256,
            alert_event=event_value,
            alert_event_sha=event_sha,
            alert_receipt=receipt_value,
            alert_receipt_sha=receipt_sha,
            restore_receipt_sha=restore_sha,
            pitr_acceptance=pitr_value,
            pitr_acceptance_sha=pitr_sha,
            active_repo2_preflight=active_repo2_preflight,
            signed_release_evidence=signed_release_evidence,
            approval=args.approval_reference,
            version=args.target_version,
            head=args.flyway_head_version,
            migration_count=args.flyway_migration_count,
            migration_set_sha=args.flyway_migration_set_sha256,
            detail_path=detail_path,
        )
        detail_sha, detail_created = _write_or_verify(detail_path, detail)
        expected_reference = f"path={detail_path};sha256={detail_sha}"
        if narrow["evidenceReference"] != expected_reference:
            raise ContractError("internal detailed receipt digest binding failed")
        try:
            narrow_sha, narrow_created = _write_or_verify(narrow_path, narrow)
        except Exception:
            # Preserve the detailed receipt as evidence; never delete or overwrite it.
            raise
        print(
            json.dumps(
                {
                    "status": (
                        "BACKUP_ACCEPTANCE_RECEIPTS_WRITTEN"
                        if detail_created or narrow_created
                        else "BACKUP_ACCEPTANCE_RECEIPTS_ALREADY_VERIFIED"
                    ),
                    "detailPath": str(detail_path),
                    "detailSha256": detail_sha,
                    "databaseReceiptPath": str(narrow_path),
                    "databaseReceiptSha256": narrow_sha,
                    "containsSecrets": False,
                },
                sort_keys=True,
            )
        )
        return 0
    except (AlertError, ContractError, OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
