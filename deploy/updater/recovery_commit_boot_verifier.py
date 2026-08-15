#!/usr/bin/env python3
"""Contain an interrupted recovery commit before employee entry can boot."""

from __future__ import annotations

import hashlib
import http.client
import fcntl
import grp
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path("/var/lib/uten-imp-release")
PENDING = ROOT / "recovery-ingress-pending.json"
AUTHORIZATION = ROOT / "recovery-ingress-authorization.json"
FINALIZING = ROOT / "recovery-ingress-finalizing.json"
FAILURE = ROOT / "activation-failed.json"
EVIDENCE = ROOT / "recovery-evidence"
OPERATION_LOCK = ROOT / "operation.lock"
MAX_JSON = 4 * 1024 * 1024
ENTRY_UNITS = (
    "uten-imp.service",
    "nginx.service",
    "uten-imp-watchdog.timer",
    "uten-imp-entry-watchdog.timer",
)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
TRANSACTION_RE = re.compile(r"^[0-9a-f]{16}-[A-Za-z0-9_-]+$")
UTC_RE = re.compile(r"^20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z$")
APPROVAL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{2,127}$")
VERSION_RE = re.compile(r"^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[1-9][0-9]{0,2}$")
DATABASE_RECEIPT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{2,127}\.json$")
DATABASE_DETAIL_REFERENCE_RE = re.compile(
    r"^path=(/var/lib/uten-imp-backup/acceptance-receipts/"
    r"[A-Za-z0-9][A-Za-z0-9._-]{2,127}\.json);sha256=([0-9a-f]{64})$"
)


class VerificationError(RuntimeError):
    pass


def strict(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    details = path.lstat()
    if (
        not stat.S_ISREG(details.st_mode)
        or path.is_symlink()
        or details.st_uid != 0
        or details.st_gid != 0
        or stat.S_IMODE(details.st_mode) != 0o600
        or details.st_nlink != 1
        or not 1 <= details.st_size <= MAX_JSON
    ):
        raise VerificationError(f"unsafe {label}")
    raw = path.read_bytes()

    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in items:
            if key in value:
                raise VerificationError(f"duplicate key in {label}")
            value[key] = item
        return value

    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(
                VerificationError(f"non-finite value in {label}: {token}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise VerificationError(f"invalid {label}") from exc
    if not isinstance(value, dict):
        raise VerificationError(f"non-object {label}")
    return value, raw


def fsync_directory(path: Path) -> None:
    descriptor = os.open(
        path,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def require_root_directory(path: Path, mode: int) -> None:
    details = path.lstat()
    if (
        not stat.S_ISDIR(details.st_mode)
        or path.is_symlink()
        or details.st_uid != 0
        or details.st_gid != 0
        or stat.S_IMODE(details.st_mode) != mode
    ):
        raise VerificationError(f"unsafe root directory: {path}")


def require_sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise VerificationError(f"invalid {label}")
    return value


def require_integer(value: Any, label: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise VerificationError(f"invalid {label}")
    return value


def validate_live_database_evidence(value: Any) -> None:
    if not isinstance(value, dict):
        raise VerificationError("recovery commit live database evidence is malformed")
    required = {
        "databaseName", "dataDirectory", "flyway", "schemaName", "serverPort",
        "serverVersionNum", "systemdMainPid", "systemIdentifier", "timeline",
        "verifiedAtUtc", "verifierSha256",
    }
    if set(value) not in (required, required | {"roleAclContractSha256"}):
        raise VerificationError("recovery commit live database evidence schema differs")
    if (
        value.get("databaseName") != "uten_imp"
        or value.get("dataDirectory") != "/data/postgresql/16/main"
        or value.get("schemaName") != "public"
        or value.get("serverPort") != 5432
        or not 160000 <= require_integer(
            value.get("serverVersionNum"), "live PostgreSQL version", 160000
        ) < 170000
        or require_integer(value.get("systemdMainPid"), "live PostgreSQL PID", 2) < 2
        or not isinstance(value.get("systemIdentifier"), str)
        or re.fullmatch(r"[0-9]{16,24}", value["systemIdentifier"]) is None
        or require_integer(value.get("timeline"), "live PostgreSQL timeline", 1)
        > 0xFFFFFFFF
        or not isinstance(value.get("verifiedAtUtc"), str)
        or UTC_RE.fullmatch(value["verifiedAtUtc"]) is None
    ):
        raise VerificationError("recovery commit live database identity differs")
    require_sha256(value.get("verifierSha256"), "live database verifier digest")
    if "roleAclContractSha256" in value:
        require_sha256(
            value.get("roleAclContractSha256"), "live role/ACL contract digest"
        )
    flyway = value.get("flyway")
    if not isinstance(flyway, dict) or set(flyway) != {
        "canonicalHistorySha256", "headVersion", "signedProjectionSha256",
        "successfulMigrationCount",
    }:
        raise VerificationError("recovery commit live Flyway evidence differs")
    require_sha256(flyway.get("canonicalHistorySha256"), "live Flyway history digest")
    require_sha256(flyway.get("signedProjectionSha256"), "live Flyway projection digest")
    require_integer(flyway.get("headVersion"), "live Flyway head", 1)
    require_integer(flyway.get("successfulMigrationCount"), "live Flyway count", 1)


def validate_database_evidence_files(value: dict[str, Any]) -> None:
    receipt_path = Path(value["databaseReceiptPath"])
    detail_path = Path(value["databaseDetailPath"])
    receipt, receipt_raw = strict(receipt_path, "database recovery receipt")
    detail, detail_raw = strict(detail_path, "detailed database recovery receipt")
    if hashlib.sha256(receipt_raw).hexdigest() != value["databaseReceiptSha256"]:
        raise VerificationError("database recovery receipt digest changed")
    if hashlib.sha256(detail_raw).hexdigest() != value["databaseDetailSha256"]:
        raise VerificationError("detailed database recovery receipt digest changed")
    if set(receipt) != {
        "approvalReference", "completedAtUtc", "evidenceReference",
        "flywayHeadVersion", "flywayMigrationSetSha256", "receiptType",
        "schemaVersion", "successful", "targetVersion",
    } or (
        receipt.get("schemaVersion") != 1
        or receipt.get("receiptType") not in {"backup", "restore"}
        or receipt.get("successful") is not True
        or receipt.get("approvalReference") != value["approvalReference"]
        or receipt.get("targetVersion") != value["targetVersion"]
        or not isinstance(receipt.get("completedAtUtc"), str)
        or UTC_RE.fullmatch(receipt["completedAtUtc"]) is None
        or not isinstance(receipt.get("flywayHeadVersion"), str)
        or not receipt["flywayHeadVersion"].isdigit()
    ):
        raise VerificationError("database recovery receipt semantics changed")
    require_sha256(
        receipt.get("flywayMigrationSetSha256"),
        "database recovery migration-set digest",
    )
    reference = receipt.get("evidenceReference")
    match = (
        DATABASE_DETAIL_REFERENCE_RE.fullmatch(reference)
        if isinstance(reference, str)
        else None
    )
    if (
        match is None
        or match.group(1) != str(detail_path)
        or match.group(2) != value["databaseDetailSha256"]
    ):
        raise VerificationError("database recovery detail reference changed")
    if (
        not isinstance(detail, dict)
        or detail.get("schemaVersion") != 1
        or detail.get("receiptType") != "backup-acceptance-detail"
        or detail.get("successful") is not True
        or detail.get("approvalReference") != receipt["approvalReference"]
        or detail.get("targetVersion") != receipt["targetVersion"]
        or detail.get("completedAtUtc") != receipt["completedAtUtc"]
        or detail.get("flywayHeadVersion") != receipt["flywayHeadVersion"]
        or detail.get("flywayMigrationSetSha256")
        != receipt["flywayMigrationSetSha256"]
    ):
        raise VerificationError("detailed database recovery receipt semantics changed")


class OperationLock:
    def __init__(self) -> None:
        self.descriptor: int | None = None

    def __enter__(self) -> "OperationLock":
        try:
            updater_gid = grp.getgrnam("uten-imp-updater").gr_gid
            descriptor = os.open(
                OPERATION_LOCK,
                os.O_RDWR
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
            )
        except (KeyError, OSError) as exc:
            raise VerificationError("cannot open the fixed release operation lock") from exc
        details = os.fstat(descriptor)
        if (
            not stat.S_ISREG(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != updater_gid
            or stat.S_IMODE(details.st_mode) != 0o660
            or details.st_nlink != 1
        ):
            os.close(descriptor)
            raise VerificationError("unsafe release operation lock")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            os.close(descriptor)
            raise VerificationError("release recovery remains active") from exc
        self.descriptor = descriptor
        return self

    def __exit__(self, *_args: Any) -> None:
        if self.descriptor is not None:
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            os.close(self.descriptor)
            self.descriptor = None


def validate_commit(value: dict[str, Any], pending: dict[str, Any]) -> None:
    expected_keys = {
        "action", "approvalReference", "committedAtUtc", "databaseDetailPath",
        "databaseDetailSha256", "databaseReceiptPath", "databaseReceiptSha256",
        "desiredBootEnablement", "liveDatabaseEvidence", "manifestSha256",
        "markerSha256", "planSha256", "schemaVersion", "status",
        "targetVersion", "transactionDirectory",
    }
    if set(value) != expected_keys or value.get("schemaVersion") != 1:
        raise VerificationError("recovery commit schema differs")
    expected_status = {
        "finish-activation": "runtime-committed-pending-ingress",
        "restore-previous": "previous-runtime-committed-pending-ingress",
        "abandon-candidate": "previous-runtime-committed-pending-ingress",
    }.get(value.get("action"))
    if expected_status is None or value.get("status") != expected_status:
        raise VerificationError("recovery commit status differs")
    for key in (
        "databaseDetailSha256", "databaseReceiptSha256", "manifestSha256",
        "markerSha256", "planSha256",
    ):
        require_sha256(value.get(key), f"recovery commit {key}")
    if (
        not isinstance(value.get("approvalReference"), str)
        or APPROVAL_RE.fullmatch(value["approvalReference"]) is None
        or not isinstance(value.get("committedAtUtc"), str)
        or UTC_RE.fullmatch(value["committedAtUtc"]) is None
        or not isinstance(value.get("targetVersion"), str)
        or VERSION_RE.fullmatch(value["targetVersion"]) is None
    ):
        raise VerificationError("recovery commit identity or chronology differs")
    desired = value.get("desiredBootEnablement")
    if (
        not isinstance(desired, dict)
        or set(desired) != set(ENTRY_UNITS)
        or any(not isinstance(item, bool) for item in desired.values())
    ):
        raise VerificationError("recovery commit boot enablement is malformed")
    transaction = Path(str(value.get("transactionDirectory", "")))
    if (
        transaction.parent != EVIDENCE
        or TRANSACTION_RE.fullmatch(transaction.name) is None
        or not transaction.name.startswith(value["planSha256"][:16] + "-")
    ):
        raise VerificationError("recovery commit transaction escaped its evidence root")
    receipt_path = Path(str(value.get("databaseReceiptPath", "")))
    detail_path = Path(str(value.get("databaseDetailPath", "")))
    if (
        receipt_path.parent != ROOT / "database-receipts"
        or DATABASE_RECEIPT_RE.fullmatch(receipt_path.name) is None
        or detail_path.parent
        != Path("/var/lib/uten-imp-backup/acceptance-receipts")
        or DATABASE_RECEIPT_RE.fullmatch(detail_path.name) is None
    ):
        raise VerificationError("recovery commit database evidence path is not canonical")
    validate_live_database_evidence(value.get("liveDatabaseEvidence"))
    validate_database_evidence_files(value)
    for key in ("action", "markerSha256", "planSha256", "targetVersion", "transactionDirectory"):
        if value.get(key) != pending.get(key):
            raise VerificationError("recovery commit differs from boot gate")


def validate_completed_receipt(
    completed: dict[str, Any], commit: dict[str, Any], transaction: Path
) -> None:
    expected = dict(commit)
    expected.pop("committedAtUtc")
    expected["completedAtUtc"] = completed.get("completedAtUtc")
    expected["status"] = "completed"
    if (
        set(completed) != set(expected)
        or completed != expected
        or not isinstance(completed.get("completedAtUtc"), str)
        or UTC_RE.fullmatch(completed["completedAtUtc"]) is None
    ):
        raise VerificationError("recovery receipt differs from the exact commit")
    _original, original_raw = strict(
        transaction / "activation-failed.original.json",
        "archived activation failure",
    )
    if hashlib.sha256(original_raw).hexdigest() != commit["markerSha256"]:
        raise VerificationError("archived activation failure differs from commit")
    progress, _progress_raw = strict(
        transaction / "recovery-in-progress.completed.json",
        "archived recovery progress",
    )
    if set(progress) != {
        "action", "approvalReference", "databaseReceiptPath",
        "databaseReceiptSha256", "desiredBootEnablement", "markerSha256",
        "planSha256", "schemaVersion", "startedAtUtc", "targetVersion",
        "transactionDirectory",
    } or any(
        progress.get(key) != commit.get(key)
        for key in (
            "action", "approvalReference", "databaseReceiptPath",
            "databaseReceiptSha256", "desiredBootEnablement", "markerSha256",
            "planSha256", "schemaVersion", "targetVersion", "transactionDirectory",
        )
    ) or not isinstance(progress.get("startedAtUtc"), str) or UTC_RE.fullmatch(
        progress["startedAtUtc"]
    ) is None:
        raise VerificationError("archived recovery progress differs from commit")
    boot, _boot_raw = strict(
        transaction / "boot-enablement.recovery.json",
        "archived boot enablement",
    )
    if set(boot) != {
        "commitSha", "desiredBootEnablement", "releaseSequence", "schemaVersion",
        "startedAtUtc", "version",
    } or (
        boot.get("schemaVersion") != 1
        or boot.get("version") != commit.get("targetVersion")
        or boot.get("desiredBootEnablement") != commit.get("desiredBootEnablement")
        or not isinstance(boot.get("commitSha"), str)
        or re.fullmatch(r"[0-9a-f]{40}", boot["commitSha"]) is None
        or not isinstance(boot.get("releaseSequence"), int)
        or isinstance(boot.get("releaseSequence"), bool)
        or not isinstance(boot.get("startedAtUtc"), str)
        or UTC_RE.fullmatch(boot["startedAtUtc"]) is None
    ):
        raise VerificationError("archived boot enablement differs from commit")


def validate_finalizing(
    value: dict[str, Any], raw: bytes
) -> tuple[Path, dict[str, Any], bytes]:
    if set(value) != {
        "action", "commitSha256", "markerSha256", "pendingSha256",
        "planSha256", "schemaVersion", "status", "targetVersion",
        "transactionDirectory",
    } or value.get("schemaVersion") != 1 or value.get("status") != (
        "RECOVERY_INGRESS_DURABLY_AUTHORIZED_PENDING_PROBES"
    ):
        raise VerificationError("recovery ingress finalization schema differs")
    for key in ("commitSha256", "markerSha256", "pendingSha256", "planSha256"):
        require_sha256(value.get(key), f"recovery finalization {key}")
    transaction = Path(str(value.get("transactionDirectory", "")))
    if (
        transaction.parent != EVIDENCE
        or TRANSACTION_RE.fullmatch(transaction.name) is None
        or not transaction.name.startswith(value["planSha256"][:16] + "-")
    ):
        raise VerificationError("recovery finalization escaped its evidence root")
    require_root_directory(EVIDENCE, 0o700)
    require_root_directory(transaction, 0o700)
    pending, pending_raw = strict(
        transaction / "recovery-ingress-pending.committed.json",
        "archived recovery ingress pending gate",
    )
    if hashlib.sha256(pending_raw).hexdigest() != value["pendingSha256"]:
        raise VerificationError("archived recovery ingress pending digest changed")
    if any(
        pending.get(key) != value.get(key)
        for key in (
            "action", "commitSha256", "markerSha256", "planSha256",
            "targetVersion", "transactionDirectory",
        )
    ):
        raise VerificationError("archived recovery ingress pending gate differs")
    commit, commit_raw = strict(transaction / "recovery-commit.json", "recovery commit")
    if hashlib.sha256(commit_raw).hexdigest() != value["commitSha256"]:
        raise VerificationError("recovery finalization commit digest changed")
    validate_commit(commit, pending)
    return transaction, commit, pending_raw


def _http_json(port: int, path: str, *, expected_status: int = 200) -> Any:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request("GET", path, headers={"Accept": "application/json", "Host": "localhost"})
        response = connection.getresponse()
        body = response.read(64 * 1024 + 1)
        if response.status != expected_status:
            raise VerificationError(f"recovery HTTP probe status differs: {path}")
        if expected_status == 404:
            return None
        if (
            len(body) > 64 * 1024
            or response.getheader("Content-Type", "").split(";", 1)[0].strip().lower()
            != "application/json"
        ):
            raise VerificationError(f"recovery HTTP probe metadata differs: {path}")
        return json.loads(body.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, http.client.HTTPException) as exc:
        raise VerificationError(f"recovery HTTP probe failed: {path}") from exc
    finally:
        connection.close()


def probe_committed_runtime(commit: dict[str, Any], transaction: Path) -> None:
    for path in (
        "/actuator/health",
        "/actuator/health/liveness",
        "/actuator/health/readiness",
    ):
        value = _http_json(8080, path)
        if not isinstance(value, dict) or value.get("status") != "UP":
            raise VerificationError(f"recovery backend health differs: {path}")
    _http_json(8080, "/actuator/info", expected_status=404)
    boot, _raw = strict(
        transaction / "boot-enablement.recovery.json", "archived boot enablement"
    )
    connection = http.client.HTTPConnection("127.0.0.1", 8081, timeout=5)
    try:
        connection.request("GET", "/index.html", headers={"Accept": "text/html", "Host": "localhost"})
        response = connection.getresponse()
        body = response.read(2 * 1024 * 1024 + 1)
        expected_meta = (
            f'<meta name="uten-release-version" content="{commit["targetVersion"]}">'
        ).encode("ascii")
        if (
            response.status != 200
            or response.getheader("Content-Type", "").split(";", 1)[0].strip().lower()
            != "text/html"
            or not 1 <= len(body) <= 2 * 1024 * 1024
            or b"flutter_bootstrap.js" not in body
            or body.count(expected_meta) != 1
        ):
            raise VerificationError("recovery static entry differs")
    except (OSError, http.client.HTTPException) as exc:
        raise VerificationError("recovery static entry probe failed") from exc
    finally:
        connection.close()
    version = _http_json(8081, "/version.json")
    if (
        not isinstance(version, dict)
        or set(version) != {"commitSha", "product", "releaseSequence", "schemaVersion", "version"}
        or version.get("schemaVersion") != 1
        or version.get("product") != "uten-imp"
        or version.get("version") != commit["targetVersion"]
        or version.get("commitSha") != boot.get("commitSha")
        or version.get("releaseSequence") != boot.get("releaseSequence")
    ):
        raise VerificationError("recovery web version identity differs")
    # Do not synchronously start watchdog units here: the entry watchdog is
    # ordered After=nginx.service, while this code is Nginx ExecStartPost, so a
    # systemctl --wait would deadlock the start job.  These direct, bounded
    # probes are exactly the safety observations the two oneshots make before
    # any self-healing branch, without taking another systemd transaction.
    liveness = _http_json(8080, "/actuator/health/liveness")
    readiness = _http_json(8080, "/actuator/health/readiness")
    if any(
        not isinstance(value, dict) or value.get("status") != "UP"
        for value in (liveness, readiness)
    ):
        raise VerificationError("recovery direct watchdog health probe differs")
    static = http.client.HTTPConnection("127.0.0.1", 8081, timeout=5)
    try:
        static.request(
            "GET", "/index.html", headers={"Accept": "text/html", "Host": "localhost"}
        )
        response = static.getresponse()
        body = response.read(2 * 1024 * 1024 + 1)
        if response.status != 200 or b"flutter_bootstrap.js" not in body:
            raise VerificationError("recovery direct entry watchdog probe differs")
    except (OSError, http.client.HTTPException) as exc:
        raise VerificationError("recovery direct entry watchdog probe failed") from exc
    finally:
        static.close()


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    payload = (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8")
    temporary = path.parent / ("." + path.name + ".incoming")
    if os.path.lexists(temporary):
        raise VerificationError("recovery terminal incoming path already exists")
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise VerificationError("recovery terminal write made no progress")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, path)
    fsync_directory(path.parent)


def finalize_ingress() -> int:
    if os.geteuid() != 0:
        return 2
    if not os.path.lexists(FINALIZING):
        return 0
    try:
        finalizing, finalizing_raw = strict(FINALIZING, "recovery ingress finalization")
        transaction, commit, _pending_raw = validate_finalizing(finalizing, finalizing_raw)
        probe_committed_runtime(commit, transaction)
        receipt_path = transaction / "recovery-receipt.json"
        if os.path.lexists(receipt_path):
            completed, _raw = strict(receipt_path, "recovery receipt")
            validate_completed_receipt(completed, commit, transaction)
        else:
            completed = dict(commit)
            completed.pop("committedAtUtc")
            completed["completedAtUtc"] = datetime_now_utc()
            completed["status"] = "completed"
            atomic_json(receipt_path, completed)
            completed, _raw = strict(receipt_path, "recovery receipt")
            validate_completed_receipt(completed, commit, transaction)
        FINALIZING.unlink()
        fsync_directory(ROOT)
        return 0
    except BaseException as exc:
        print(f"RECOVERY_INGRESS_FINALIZE_NO_GO: {exc}", file=sys.stderr)
        # EX_CONFIG is pinned by the Nginx unit's RestartPreventExitStatus.
        # A failed post-start safety proof must stop this start job without
        # allowing Restart=on-failure to expose repeated short listen windows.
        return 78


def datetime_now_utc() -> str:
    from datetime import datetime, timezone

    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def validate_probe_authorization(
    value: dict[str, Any], pending_raw: bytes, transaction: Path
) -> None:
    if set(value) != {
        "bootId",
        "issuerPid",
        "issuerStartTimeTicks",
        "issuerCommandLineSha256",
        "issuerExecutablePath",
        "issuerExecutableSha256",
        "issuedAtUtc",
        "pendingSha256",
        "schemaVersion",
        "status",
        "transactionDirectory",
    } or value.get("schemaVersion") != 1 or value.get("status") != "RECOVERY_INGRESS_PROBE_AUTHORIZED":
        raise VerificationError("recovery probe authorization schema differs")
    if (
        not isinstance(value.get("bootId"), str)
        or re.fullmatch(
            r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
            value["bootId"],
        )
        is None
        or not isinstance(value.get("issuedAtUtc"), str)
        or UTC_RE.fullmatch(value["issuedAtUtc"]) is None
        or value.get("transactionDirectory") != str(transaction)
        or value.get("pendingSha256") != hashlib.sha256(pending_raw).hexdigest()
        or not isinstance(value.get("issuerPid"), int)
        or isinstance(value.get("issuerPid"), bool)
        or value["issuerPid"] <= 1
        or not isinstance(value.get("issuerStartTimeTicks"), int)
        or isinstance(value.get("issuerStartTimeTicks"), bool)
        or value["issuerStartTimeTicks"] <= 0
        or not isinstance(value.get("issuerCommandLineSha256"), str)
        or SHA256_RE.fullmatch(value["issuerCommandLineSha256"]) is None
        or not isinstance(value.get("issuerExecutableSha256"), str)
        or SHA256_RE.fullmatch(value["issuerExecutableSha256"]) is None
        or not isinstance(value.get("issuerExecutablePath"), str)
        or not value["issuerExecutablePath"].startswith("/usr/bin/python3")
    ):
        raise VerificationError("recovery probe authorization differs from pending")


def remove_probe_authorization_if_present(
    *, pending_raw: bytes, transaction: Path
) -> None:
    if not os.path.lexists(AUTHORIZATION):
        return
    authorization, _raw = strict(
        AUTHORIZATION, "recovery ingress probe authorization"
    )
    validate_probe_authorization(authorization, pending_raw, transaction)
    AUTHORIZATION.unlink()
    fsync_directory(ROOT)


def converge_entry_unit_closed(unit: str) -> None:
    result = subprocess.run(
        ["/usr/bin/systemctl", "disable", "--now", unit],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        raise VerificationError(f"cannot close entry unit: {unit}")
    state = subprocess.run(
        [
            "/usr/bin/systemctl", "show", unit,
            "--property=ActiveState", "--property=UnitFileState",
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    try:
        values = dict(
            line.split("=", 1)
            for line in state.stdout.decode("ascii").splitlines()
            if "=" in line
        )
    except UnicodeDecodeError as exc:
        raise VerificationError(f"cannot read entry unit state: {unit}") from exc
    if (
        state.returncode != 0
        or values.get("ActiveState") != "inactive"
        or values.get("UnitFileState") != "disabled"
    ):
        raise VerificationError(f"entry unit did not close durably: {unit}")


def contain(pending: dict[str, Any], pending_raw: bytes, transaction: Path) -> None:
    original = transaction / "activation-failed.original.json"
    original_value, original_raw = strict(original, "archived activation failure")
    if hashlib.sha256(original_raw).hexdigest() != pending["markerSha256"]:
        raise VerificationError("archived activation failure digest changed")
    for unit in ENTRY_UNITS:
        converge_entry_unit_closed(unit)
    if os.path.lexists(FAILURE):
        live, live_raw = strict(FAILURE, "live activation failure")
        if live != original_value or live_raw != original_raw:
            raise VerificationError("another activation failure gate is live")
    else:
        temporary = ROOT / ".activation-failed.recovery-boot.incoming"
        if os.path.lexists(temporary):
            raise VerificationError("activation failure incoming path exists")
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
            0o600,
        )
        try:
            offset = 0
            while offset < len(original_raw):
                written = os.write(descriptor, original_raw[offset:])
                if written <= 0:
                    raise VerificationError("activation failure write made no progress")
                offset += written
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.replace(temporary, FAILURE)
        fsync_directory(ROOT)
    # The ordinary evidence-driven recovery path is now safely available.  The
    # short-lived probe grant is removed first so no crash can expose ingress.
    remove_probe_authorization_if_present(
        pending_raw=pending_raw, transaction=transaction
    )
    if os.path.lexists(PENDING):
        PENDING.unlink()
        fsync_directory(ROOT)
    if os.path.lexists(FINALIZING):
        FINALIZING.unlink()
        fsync_directory(ROOT)


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--finalize-ingress":
        return finalize_ingress()
    if len(sys.argv) != 1 or os.geteuid() != 0:
        return 2
    if not os.path.lexists(PENDING):
        if os.path.lexists(AUTHORIZATION):
            print(
                "RECOVERY_BOOT_NO_GO: orphaned recovery probe authorization exists",
                file=sys.stderr,
            )
            return 1
        if os.path.lexists(FINALIZING):
            try:
                with OperationLock():
                    finalizing, finalizing_raw = strict(
                        FINALIZING, "recovery ingress finalization"
                    )
                    transaction, commit, pending_raw = validate_finalizing(
                        finalizing, finalizing_raw
                    )
                    receipt_path = transaction / "recovery-receipt.json"
                    if os.path.lexists(receipt_path):
                        completed, _receipt_raw = strict(
                            receipt_path, "recovery receipt"
                        )
                        validate_completed_receipt(completed, commit, transaction)
                        FINALIZING.unlink()
                        fsync_directory(ROOT)
                    else:
                        pending, _archived_raw = strict(
                            transaction / "recovery-ingress-pending.committed.json",
                            "archived recovery ingress pending gate",
                        )
                        contain(pending, pending_raw, transaction)
                return 0
            except (OSError, VerificationError) as exc:
                print(f"RECOVERY_BOOT_NO_GO: {exc}", file=sys.stderr)
                return 1
        return 0
    try:
        with OperationLock():
            pending, pending_raw = strict(PENDING, "recovery ingress pending gate")
            if set(pending) != {
                "action",
                "commitSha256",
                "markerSha256",
                "planSha256",
                "schemaVersion",
                "status",
                "targetVersion",
                "transactionDirectory",
            } or pending.get("schemaVersion") != 1 or pending.get("status") != "RECOVERY_COMMITTED_PENDING_INGRESS":
                raise VerificationError("recovery ingress pending schema differs")
            for key in ("commitSha256", "markerSha256", "planSha256"):
                require_sha256(pending.get(key), f"pending {key}")
            transaction = Path(str(pending.get("transactionDirectory", "")))
            if (
                transaction.parent != EVIDENCE
                or TRANSACTION_RE.fullmatch(transaction.name) is None
                or not transaction.name.startswith(
                    str(pending["planSha256"])[:16] + "-"
                )
            ):
                raise VerificationError("recovery transaction escaped its evidence root")
            require_root_directory(EVIDENCE, 0o700)
            require_root_directory(transaction, 0o700)
            commit, commit_raw = strict(transaction / "recovery-commit.json", "recovery commit")
            if hashlib.sha256(commit_raw).hexdigest() != pending.get("commitSha256"):
                raise VerificationError("recovery commit digest changed")
            validate_commit(commit, pending)
            if os.path.lexists(FINALIZING):
                finalizing, finalizing_raw = strict(
                    FINALIZING, "recovery ingress finalization"
                )
                if any(
                    finalizing.get(key) != pending.get(key)
                    for key in (
                        "action", "commitSha256", "markerSha256", "planSha256",
                        "targetVersion", "transactionDirectory",
                    )
                ) or finalizing.get("pendingSha256") != hashlib.sha256(
                    pending_raw
                ).hexdigest():
                    raise VerificationError(
                        "recovery finalization differs from the live pending gate"
                    )
            receipt = transaction / "recovery-receipt.json"
            if os.path.lexists(receipt):
                completed, _completed_raw = strict(receipt, "recovery receipt")
                validate_completed_receipt(completed, commit, transaction)
                remove_probe_authorization_if_present(
                    pending_raw=pending_raw, transaction=transaction
                )
                PENDING.unlink()
                fsync_directory(ROOT)
            else:
                contain(pending, pending_raw, transaction)
        return 0
    except (OSError, VerificationError) as exc:
        print(f"RECOVERY_BOOT_NO_GO: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
