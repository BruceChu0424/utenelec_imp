#!/usr/bin/env python3
"""Durable, secret-free external alert spool for ERP backup failures.

The trusted external bridge has one fixed production path and receives only
file paths: ``submit --event-file FILE --receipt-file FILE``.  A zero exit is
not enough; the bridge must create the exact acknowledgement receipt described
in README.zh-CN.md or the event remains pending and this command fails.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import fcntl
except ImportError:  # pragma: no cover - production is POSIX; enables static Windows QA.
    fcntl = None  # type: ignore[assignment]


SCHEMA_VERSION = 1
DEFAULT_STATE = Path("/var/lib/uten-imp-backup-alerts")
DEFAULT_HEALTH_REPORT = Path("/var/lib/uten-imp-backup-health/health.json")
FIXED_SENDER = Path("/usr/local/libexec/uten-imp-alerting/submit")
ALLOWED_UNITS = {
    "uten-pgbackup.service",
    "uten-pgbackup-repo2.service",
    "uten-pgbackup-health.service",
    "uten-pgbackup-alert-drain.service",
}
UTC_TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
MESSAGE_ID = re.compile(r"^[A-Za-z0-9._:@/-]{3,256}$")
EVENT_ID = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}$")
MAX_PENDING_EVENTS = 1000
MAX_PENDING_BYTES = 16 * 1024 * 1024


class AlertError(RuntimeError):
    """Alert delivery contract failure."""


def _canonical(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _atomic_new(path: Path, payload: bytes, mode: int = 0o600) -> None:
    if path.exists() or path.is_symlink():
        raise AlertError(f"refusing to overwrite alert state: {path}")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written < 1:
                raise OSError("short alert-state write")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    _fsync_directory(path.parent)


def _secure_regular(path: Path, maximum_bytes: int) -> bytes:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise AlertError(f"alert file is not one regular file: {path}")
    if info.st_size > maximum_bytes:
        raise AlertError(f"alert file exceeds size limit: {path}")
    flags = os.O_RDONLY | os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
            raise AlertError("alert file changed during verification")
        return os.read(descriptor, maximum_bytes + 1)
    finally:
        os.close(descriptor)


def _assert_root_private_file(path: Path, label: str) -> None:
    info = path.lstat()
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != 0
        or info.st_gid != 0
        or info.st_nlink != 1
        or stat.S_IMODE(info.st_mode) != 0o600
    ):
        raise AlertError(f"{label} must be root:root 0600 with one link")


def _prepare_state(state: Path) -> None:
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    if state.is_symlink() or not state.is_dir():
        raise AlertError(f"unsafe alert state directory: {state}")
    for name in ("pending", "delivered", "receipts", "work", "rejected"):
        child = state / name
        child.mkdir(mode=0o700, exist_ok=True)
        if child.is_symlink() or not child.is_dir():
            raise AlertError(f"unsafe alert state directory: {child}")
    if os.environ.get("UTEN_BACKUP_ALERT_TEST_MODE") != "1":
        for directory in (
            state,
            state / "pending",
            state / "delivered",
            state / "receipts",
            state / "work",
            state / "rejected",
        ):
            info = directory.lstat()
            if (
                info.st_uid != 0
                or info.st_gid != 0
                or stat.S_IMODE(info.st_mode) != 0o700
            ):
                raise AlertError(f"production alert state must be root:root 0700: {directory}")


def _pending_capacity(state: Path) -> None:
    entries = list((state / "pending").glob("*.json"))
    if len(entries) >= MAX_PENDING_EVENTS:
        raise AlertError("backup alert pending-event quota is full")
    total = 0
    for item in entries:
        try:
            info = item.lstat()
        except FileNotFoundError:
            continue
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise AlertError("unsafe object exists in backup alert pending spool")
        total += info.st_size
    if total >= MAX_PENDING_BYTES:
        raise AlertError("backup alert pending-byte quota is full")


def _health_summary(path: Path) -> tuple[str | None, str]:
    if not path.exists():
        return None, "backup health report is missing"
    raw = _secure_regular(path, 1024 * 1024)
    digest = hashlib.sha256(raw).hexdigest()
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return digest, "backup health report is invalid"
    failure = value.get("failure") if isinstance(value, dict) else None
    if not isinstance(failure, str) or not failure:
        failure = f"backup health status={value.get('status', 'unknown')}" if isinstance(value, dict) else "backup health failed"
    cleaned = " ".join(failure.split())[:512]
    if re.search(r"(?i)(password|passwd|secret|token|credential|access[_-]?key)", cleaned):
        cleaned = "backup health failed; inspect the local root-only health report"
    return digest, cleaned


def create_event(unit: str, health_report: Path, now: datetime | None = None) -> dict[str, Any]:
    if unit not in ALLOWED_UNITS:
        raise AlertError("unit is outside the backup alert allowlist")
    current = now or datetime.now(timezone.utc)
    event_id = current.strftime("%Y%m%dT%H%M%SZ-") + secrets.token_hex(16)
    digest, summary = _health_summary(health_report)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "eventId": event_id,
        "severity": "critical",
        "source": "uten-imp-postgresql-backup",
        "unit": unit,
        "occurredAtUtc": current.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": summary,
        "healthReportSha256": digest,
        "containsSecrets": False,
        "requiredAction": "acknowledge, investigate backup/WAL health, and run an approved restore drill",
    }


def validate_event(value: Any) -> dict[str, Any]:
    expected = {
        "schemaVersion",
        "eventId",
        "severity",
        "source",
        "unit",
        "occurredAtUtc",
        "summary",
        "healthReportSha256",
        "containsSecrets",
        "requiredAction",
    }
    if not isinstance(value, dict) or set(value) != expected:
        raise AlertError("pending alert event has an unexpected schema")
    if value["schemaVersion"] != 1 or value["severity"] != "critical":
        raise AlertError("pending alert event version/severity is invalid")
    if value["source"] != "uten-imp-postgresql-backup" or value["unit"] not in ALLOWED_UNITS:
        raise AlertError("pending alert event identity is invalid")
    if not isinstance(value["eventId"], str) or not EVENT_ID.fullmatch(value["eventId"]):
        raise AlertError("pending alert event id is invalid")
    if not isinstance(value["occurredAtUtc"], str) or not UTC_TIMESTAMP.fullmatch(value["occurredAtUtc"]):
        raise AlertError("pending alert timestamp is invalid")
    if value["containsSecrets"] is not False:
        raise AlertError("pending alert must explicitly contain no secrets")
    if not isinstance(value["summary"], str) or not 1 <= len(value["summary"]) <= 512:
        raise AlertError("pending alert summary is invalid")
    digest = value["healthReportSha256"]
    if digest is not None and (not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)):
        raise AlertError("pending alert health report digest is invalid")
    return value


def validate_receipt(path: Path, event: dict[str, Any]) -> dict[str, Any]:
    raw = _secure_regular(path, 64 * 1024)
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AlertError("external alert receipt is not UTF-8 JSON") from exc
    expected = {"schemaVersion", "eventId", "accepted", "deliveredAtUtc", "providerMessageId"}
    if not isinstance(value, dict) or set(value) != expected:
        raise AlertError("external alert receipt schema differs")
    if value["schemaVersion"] != 1 or value["eventId"] != event["eventId"] or value["accepted"] is not True:
        raise AlertError("external alert receipt does not acknowledge this event")
    if not isinstance(value["deliveredAtUtc"], str) or not UTC_TIMESTAMP.fullmatch(value["deliveredAtUtc"]):
        raise AlertError("external alert receipt timestamp is invalid")
    occurred_at = datetime.strptime(
        event["occurredAtUtc"], "%Y-%m-%dT%H:%M:%SZ"
    ).replace(tzinfo=timezone.utc)
    delivered_at = datetime.strptime(
        value["deliveredAtUtc"], "%Y-%m-%dT%H:%M:%SZ"
    ).replace(tzinfo=timezone.utc)
    if delivered_at < occurred_at or delivered_at > datetime.now(timezone.utc):
        raise AlertError("external alert receipt delivery time is not credible")
    if not isinstance(value["providerMessageId"], str) or not MESSAGE_ID.fullmatch(value["providerMessageId"]):
        raise AlertError("external alert provider message id is invalid")
    return value


def _quarantine_work_receipt(path: Path, state: Path, event_id: str) -> None:
    if not path.exists() and not path.is_symlink():
        return
    destination = state / "rejected" / f"{event_id}-{secrets.token_hex(16)}.json"
    if destination.exists() or destination.is_symlink():
        raise AlertError("external alert rejected-receipt destination already exists")
    os.replace(path, destination)
    _fsync_directory(path.parent)
    _fsync_directory(destination.parent)


def _complete_delivery(
    event_path: Path,
    state: Path,
    event: dict[str, Any],
    receipt_path: Path,
    production: bool,
    *,
    final_already_written: bool,
) -> None:
    if production:
        _assert_root_private_file(receipt_path, "external alert receipt")
    receipt = validate_receipt(receipt_path, event)
    final_receipt = state / "receipts" / f"{event['eventId']}.json"
    delivered = state / "delivered" / f"{event['eventId']}.json"
    if delivered.exists() or delivered.is_symlink():
        raise AlertError("external alert delivered evidence already exists")
    if final_already_written:
        if receipt_path != final_receipt:
            raise AlertError("internal final receipt path mismatch")
    else:
        if final_receipt.exists() or final_receipt.is_symlink():
            raise AlertError("external alert final receipt already exists")
        _atomic_new(final_receipt, _canonical(receipt))
    os.replace(event_path, delivered)
    _fsync_directory(event_path.parent)
    _fsync_directory(delivered.parent)


def deliver_event(event_path: Path, state: Path, sender: Path = FIXED_SENDER) -> bool:
    production = os.environ.get("UTEN_BACKUP_ALERT_TEST_MODE") != "1"
    if production:
        _assert_root_private_file(event_path, "pending alert event")
    raw = _secure_regular(event_path, 64 * 1024)
    original_digest = hashlib.sha256(raw).hexdigest()
    try:
        event = validate_event(json.loads(raw.decode("utf-8")))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AlertError("pending alert is not UTF-8 JSON") from exc
    if sender != FIXED_SENDER and production:
        raise AlertError("production sender path is fixed")
    final_receipt = state / "receipts" / f"{event['eventId']}.json"
    delivered = state / "delivered" / f"{event['eventId']}.json"
    receipt_work = state / "work" / f"{event['eventId']}.receipt.json"
    if delivered.exists() or delivered.is_symlink():
        raise AlertError("pending and delivered copies of one alert both exist")
    if final_receipt.exists() or final_receipt.is_symlink():
        _complete_delivery(
            event_path,
            state,
            event,
            final_receipt,
            production,
            final_already_written=True,
        )
        if receipt_work.exists() or receipt_work.is_symlink():
            _quarantine_work_receipt(receipt_work, state, event["eventId"])
        return True
    if receipt_work.exists() or receipt_work.is_symlink():
        try:
            _complete_delivery(
                event_path,
                state,
                event,
                receipt_work,
                production,
                final_already_written=False,
            )
        except (AlertError, OSError):
            _quarantine_work_receipt(receipt_work, state, event["eventId"])
        else:
            receipt_work.unlink()
            _fsync_directory(receipt_work.parent)
            return True
    if not sender.is_file() or sender.is_symlink():
        return False
    if production:
        sender_info = sender.lstat()
        if (
            sender_info.st_uid != 0
            or sender_info.st_nlink != 1
            or sender_info.st_mode & 0o022
            or not sender_info.st_mode & 0o100
        ):
            raise AlertError("external alert sender must be root-owned, non-writable and executable")
    result = subprocess.run(
        [str(sender), "--event-file", str(event_path), "--receipt-file", str(receipt_work)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"},
        timeout=60,
        check=False,
    )
    if result.returncode != 0 or not receipt_work.exists():
        _quarantine_work_receipt(receipt_work, state, event["eventId"])
        return False
    if production:
        _assert_root_private_file(receipt_work, "external alert receipt work file")
    if hashlib.sha256(_secure_regular(event_path, 64 * 1024)).hexdigest() != original_digest:
        raise AlertError("pending alert changed while the external sender ran")
    try:
        _complete_delivery(
            event_path,
            state,
            event,
            receipt_work,
            production,
            final_already_written=False,
        )
    except (AlertError, OSError):
        _quarantine_work_receipt(receipt_work, state, event["eventId"])
        return False
    receipt_work.unlink()
    _fsync_directory(receipt_work.parent)
    return True


def emit(unit: str, state: Path, health_report: Path, sender: Path = FIXED_SENDER) -> bool:
    if fcntl is None:
        raise AlertError("backup alert spool requires POSIX flock support")
    _prepare_state(state)
    lock_path = state / "operation.lock"
    lock_descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        if os.environ.get("UTEN_BACKUP_ALERT_TEST_MODE") != "1":
            lock_info = os.fstat(lock_descriptor)
            if (
                not stat.S_ISREG(lock_info.st_mode)
                or lock_info.st_uid != 0
                or lock_info.st_gid != 0
                or lock_info.st_nlink != 1
                or stat.S_IMODE(lock_info.st_mode) != 0o600
            ):
                raise AlertError("backup alert operation lock must be root:root 0600 with one link")
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX)
        _pending_capacity(state)
        for pending_path in sorted((state / "pending").glob("*.json")):
            pending_raw = _secure_regular(pending_path, 64 * 1024)
            try:
                pending_value = validate_event(json.loads(pending_raw.decode("utf-8")))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise AlertError("existing pending alert is not UTF-8 JSON") from exc
            if pending_value["unit"] == unit:
                return deliver_event(pending_path, state, sender)
        event = create_event(unit, health_report)
        event_path = state / "pending" / f"{event['eventId']}.json"
        _atomic_new(event_path, _canonical(event))
        return deliver_event(event_path, state, sender)
    finally:
        os.close(lock_descriptor)


def drain(state: Path, sender: Path = FIXED_SENDER) -> tuple[int, int]:
    if fcntl is None:
        raise AlertError("backup alert spool requires POSIX flock support")
    _prepare_state(state)
    lock_path = state / "operation.lock"
    lock_descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    delivered = 0
    pending = 0
    try:
        if os.environ.get("UTEN_BACKUP_ALERT_TEST_MODE") != "1":
            lock_info = os.fstat(lock_descriptor)
            if (
                not stat.S_ISREG(lock_info.st_mode)
                or lock_info.st_uid != 0
                or lock_info.st_gid != 0
                or lock_info.st_nlink != 1
                or stat.S_IMODE(lock_info.st_mode) != 0o600
            ):
                raise AlertError("backup alert operation lock must be root:root 0600 with one link")
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX)
        events = sorted((state / "pending").glob("*.json"))
        if len(events) > MAX_PENDING_EVENTS:
            raise AlertError("backup alert pending-event quota is exceeded")
        for event_path in events:
            if deliver_event(event_path, state, sender):
                delivered += 1
            else:
                pending += 1
        return delivered, pending
    finally:
        os.close(lock_descriptor)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    emit_parser = sub.add_parser("emit")
    emit_parser.add_argument("--unit", required=True)
    emit_parser.add_argument("--state", type=Path, default=DEFAULT_STATE)
    emit_parser.add_argument("--health-report", type=Path, default=DEFAULT_HEALTH_REPORT)
    drain_parser = sub.add_parser("drain")
    drain_parser.add_argument("--state", type=Path, default=DEFAULT_STATE)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if os.name != "posix" or os.geteuid() != 0:
            raise AlertError("backup alert spool requires root on POSIX")
        if args.state != DEFAULT_STATE:
            raise AlertError("production backup alert state path is fixed")
        if args.action == "emit" and args.health_report != DEFAULT_HEALTH_REPORT:
            raise AlertError("production backup health report path is fixed")
        if args.action == "emit":
            delivered = emit(args.unit, args.state, args.health_report)
            print(json.dumps({"status": "DELIVERED" if delivered else "PENDING", "unit": args.unit}))
            return 0 if delivered else 1
        delivered, pending = drain(args.state)
        print(json.dumps({"status": "PASS" if pending == 0 else "PENDING", "delivered": delivered, "pending": pending}))
        return 0 if pending == 0 else 1
    except (AlertError, OSError, subprocess.TimeoutExpired) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
