#!/usr/bin/env python3
"""Crash-safe, bounded, secret-free alert spool for runtime monitoring.

The monitor services only record normalized local events.  A separate network
service invokes the fixed root-controlled bridge at
``/usr/local/libexec/uten-imp-alerting/submit``.  A zero exit is not delivery:
the bridge must durably return the exact receipt bound to the event ID.
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
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import fcntl
except ImportError:  # pragma: no cover - production is POSIX.
    fcntl = None  # type: ignore[assignment]


try:
    common = sys.modules["uten_imp_monitoring_common"]
except KeyError as exc:  # pragma: no cover - launcher/contract tests exercise it.
    raise RuntimeError(
        "alert spool must be executed through monitor_runtime_launcher.py"
    ) from exc


DEFAULT_STATE = Path("/var/lib/uten-imp-monitoring")
HOST_REPORT = DEFAULT_STATE / "host-latest.json"
EXTERNAL_REPORT = DEFAULT_STATE / "external-latest.json"
FIXED_SENDER = Path("/usr/local/libexec/uten-imp-alerting/submit")
ALLOWED_FAILURE_UNITS = {
    "uten-imp-host-monitor.service",
    "uten-imp-external-monitor.service",
}
REPORT_FORMATS = {
    "host": "uten-imp-host-monitor-report-v1",
    "external": "uten-imp-external-monitor-report-v1",
}
EVENT_ID = re.compile(r"^\d{8}T\d{6}Z-[0-9a-f]{32}$")
EPISODE_ID = re.compile(r"^[0-9a-f]{32}$")
MESSAGE_ID = re.compile(r"^[A-Za-z0-9._:@/-]{3,256}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MAX_PENDING_EVENTS = 1000
MAX_PENDING_BYTES = 16 * 1024 * 1024
MAX_REJECTED_RECEIPTS = 1000
MAX_TRACKED_CODES = 512
TEMPORARY_FAILURE = 75


class AlertError(common.MonitoringError):
    """The durable alert state or delivery receipt is unsafe."""


def _production() -> bool:
    return not common.test_mode()


def _paths(state: Path) -> dict[str, Path]:
    alerts = state / "alerts"
    return {
        "alerts": alerts,
        "pending": alerts / "pending",
        "delivered": alerts / "delivered",
        "receipts": alerts / "receipts",
        "work": alerts / "work",
        "rejected": alerts / "rejected",
        "active": alerts / "active.json",
        "transition": alerts / "transition.json",
        "lock": alerts / "operation.lock",
    }


def _prepare_state(state: Path) -> dict[str, Path]:
    common.assert_private_directory(state, create=True)
    paths = _paths(state)
    for key in ("alerts", "pending", "delivered", "receipts", "work", "rejected"):
        common.assert_private_directory(paths[key], create=True)
    return paths


class _Lock:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.descriptor = -1

    def __enter__(self) -> "_Lock":
        if fcntl is None and _production():
            raise AlertError("production monitoring alert spool requires POSIX flock")
        self.descriptor = os.open(
            self.path,
            os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        details = os.fstat(self.descriptor)
        if not stat.S_ISREG(details.st_mode) or details.st_nlink != 1:
            raise AlertError("alert operation lock is unsafe")
        if _production() and (
            details.st_uid != 0
            or details.st_gid != 0
            or stat.S_IMODE(details.st_mode) != 0o600
        ):
            raise AlertError("alert operation lock must be root:root 0600")
        if fcntl is not None:
            fcntl.flock(self.descriptor, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_: object) -> None:
        if self.descriptor >= 0:
            os.close(self.descriptor)
            self.descriptor = -1


def _read_private_json(path: Path, maximum: int = 64 * 1024) -> tuple[bytes, Any]:
    return common.read_json_file(
        path,
        canonical=True,
        expected_mode=0o600,
        require_root=True,
        maximum=maximum,
    )


def _validate_issue(value: Any) -> dict[str, str]:
    expected = {"code", "severity", "summary", "requiredAction"}
    if not isinstance(value, dict) or set(value) != expected:
        raise AlertError("monitor report issue schema differs")
    if not isinstance(value["code"], str) or not common.ISSUE_CODE.fullmatch(
        value["code"]
    ):
        raise AlertError("monitor report issue code is invalid")
    if value["severity"] not in {"warning", "critical"}:
        raise AlertError("monitor report issue severity is invalid")
    for field in ("summary", "requiredAction"):
        if not isinstance(value[field], str) or not 1 <= len(value[field]) <= 512:
            raise AlertError(f"monitor report issue {field} is invalid")
    return value


def validate_report(value: Any, raw: bytes, source: str) -> dict[str, Any]:
    expected = {
        "format",
        "source",
        "observedAtUtc",
        "bootId",
        "policySha256",
        "status",
        "issues",
        "evidence",
        "containsSecrets",
    }
    if not isinstance(value, dict) or set(value) != expected:
        raise AlertError("monitor report schema differs")
    if source not in REPORT_FORMATS or value["format"] != REPORT_FORMATS[source]:
        raise AlertError("monitor report format differs from its source")
    if value["source"] != source or value["containsSecrets"] is not False:
        raise AlertError("monitor report source/secrecy declaration differs")
    common.parse_utc(value["observedAtUtc"])
    if not isinstance(value["bootId"], str) or not re.fullmatch(
        r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}|test-boot",
        value["bootId"],
    ):
        raise AlertError("monitor report boot ID is invalid")
    if not isinstance(value["policySha256"], str) or not SHA256.fullmatch(
        value["policySha256"]
    ):
        raise AlertError("monitor report policy digest is invalid")
    if not isinstance(value["issues"], list):
        raise AlertError("monitor report issues is not a list")
    issues = [_validate_issue(item) for item in value["issues"]]
    if len(issues) > MAX_TRACKED_CODES or len({item["code"] for item in issues}) != len(
        issues
    ):
        raise AlertError("monitor report issue codes are excessive or duplicated")
    expected_status = "PASS" if not issues else "FAIL"
    if value["status"] != expected_status or not isinstance(value["evidence"], dict):
        raise AlertError("monitor report status/evidence is invalid")
    if common.canonical_json(value) != raw:
        raise AlertError("monitor report changed after canonical validation")
    return value


def _empty_active(now: str) -> dict[str, Any]:
    return {
        "format": "uten-imp-monitor-active-alerts-v1",
        "entries": {"host": {}, "external": {}},
        "updatedAtUtc": now,
    }


def _validate_active(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {"format", "entries", "updatedAtUtc"}:
        raise AlertError("active-alert state schema differs")
    if value["format"] != "uten-imp-monitor-active-alerts-v1":
        raise AlertError("active-alert state format differs")
    common.parse_utc(value["updatedAtUtc"])
    entries = value["entries"]
    if not isinstance(entries, dict) or set(entries) != {"host", "external"}:
        raise AlertError("active-alert source map differs")
    total = 0
    for source, values in entries.items():
        if not isinstance(values, dict):
            raise AlertError("active-alert code map is invalid")
        total += len(values)
        for code, item in values.items():
            if not isinstance(code, str) or not common.ISSUE_CODE.fullmatch(code):
                raise AlertError("active-alert code is invalid")
            expected = {
                "state",
                "episodeId",
                "signature",
                "severity",
                "summary",
                "requiredAction",
                "lastReportSha256",
                "lastChangedAtUtc",
            }
            if not isinstance(item, dict) or set(item) != expected:
                raise AlertError("active-alert entry schema differs")
            if item["state"] not in {"active", "clear"}:
                raise AlertError("active-alert entry state is invalid")
            if not EPISODE_ID.fullmatch(str(item["episodeId"])):
                raise AlertError("active-alert episode is invalid")
            if not SHA256.fullmatch(str(item["signature"])) or not SHA256.fullmatch(
                str(item["lastReportSha256"])
            ):
                raise AlertError("active-alert digest is invalid")
            if item["severity"] not in {"warning", "critical"}:
                raise AlertError("active-alert severity is invalid")
            for key in ("summary", "requiredAction"):
                if not isinstance(item[key], str) or not 1 <= len(item[key]) <= 512:
                    raise AlertError("active-alert text is invalid")
            common.parse_utc(item["lastChangedAtUtc"])
    if total > MAX_TRACKED_CODES:
        raise AlertError("active-alert state tracks too many issue codes")
    return value


def _load_active(path: Path, now: str) -> dict[str, Any]:
    if not path.exists() and not path.is_symlink():
        return _empty_active(now)
    _, value = _read_private_json(path, maximum=512 * 1024)
    return _validate_active(value)


def _event_id(now: datetime) -> str:
    return now.strftime("%Y%m%dT%H%M%SZ-") + secrets.token_hex(16)


def _issue_signature(item: dict[str, str]) -> str:
    return hashlib.sha256(common.canonical_json(item)).hexdigest()


def _event(
    *,
    source: str,
    kind: str,
    entry: dict[str, Any],
    code: str,
    report_sha: str,
    now: datetime,
) -> dict[str, Any]:
    severity = entry["severity"] if kind != "recovered" else "warning"
    summary = entry["summary"]
    action = entry["requiredAction"]
    if kind == "recovered":
        summary = f"Recovered: {summary}"
        action = "verify the recovery is durable and close the incident with the linked evidence"
    return {
        "format": "uten-imp-monitor-alert-v1",
        "eventId": _event_id(now),
        "episodeId": entry["episodeId"],
        "source": source,
        "kind": kind,
        "code": code,
        "severity": severity,
        "occurredAtUtc": common.utc_text(now),
        "summary": summary,
        "requiredAction": action,
        "reportSha256": report_sha,
        "containsSecrets": False,
    }


def validate_event(value: Any) -> dict[str, Any]:
    expected = {
        "format",
        "eventId",
        "episodeId",
        "source",
        "kind",
        "code",
        "severity",
        "occurredAtUtc",
        "summary",
        "requiredAction",
        "reportSha256",
        "containsSecrets",
    }
    if not isinstance(value, dict) or set(value) != expected:
        raise AlertError("alert event schema differs")
    if value["format"] != "uten-imp-monitor-alert-v1":
        raise AlertError("alert event format differs")
    if not EVENT_ID.fullmatch(str(value["eventId"])) or not EPISODE_ID.fullmatch(
        str(value["episodeId"])
    ):
        raise AlertError("alert event identity is invalid")
    if value["source"] not in REPORT_FORMATS or value["kind"] not in {
        "opened",
        "updated",
        "recovered",
        "monitor-failed",
    }:
        raise AlertError("alert event source/kind is invalid")
    if not common.ISSUE_CODE.fullmatch(str(value["code"])):
        raise AlertError("alert event code is invalid")
    if value["severity"] not in {"warning", "critical"}:
        raise AlertError("alert event severity is invalid")
    common.parse_utc(value["occurredAtUtc"])
    for key in ("summary", "requiredAction"):
        if not isinstance(value[key], str) or not 1 <= len(value[key]) <= 512:
            raise AlertError("alert event text is invalid")
    if not SHA256.fullmatch(str(value["reportSha256"])):
        raise AlertError("alert event report digest is invalid")
    if value["containsSecrets"] is not False:
        raise AlertError("alert event must explicitly contain no secrets")
    return value


def _pending_capacity(paths: dict[str, Path], additions: list[bytes]) -> None:
    entries = list(paths["pending"].glob("*.json"))
    if len(entries) + len(additions) > MAX_PENDING_EVENTS:
        raise AlertError("monitor alert pending-event quota would be exceeded")
    total = sum(len(item) for item in additions)
    for path in entries:
        info = path.lstat()
        if path.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise AlertError("unsafe object exists in pending alert spool")
        total += info.st_size
    if total > MAX_PENDING_BYTES:
        raise AlertError("monitor alert pending-byte quota would be exceeded")


def _validate_transition(value: Any) -> dict[str, Any]:
    expected = {"format", "source", "reportSha256", "events", "activeState"}
    if not isinstance(value, dict) or set(value) != expected:
        raise AlertError("alert transition schema differs")
    if value["format"] != "uten-imp-monitor-alert-transition-v1":
        raise AlertError("alert transition format differs")
    if value["source"] not in REPORT_FORMATS or not SHA256.fullmatch(
        str(value["reportSha256"])
    ):
        raise AlertError("alert transition source/digest is invalid")
    if not isinstance(value["events"], list):
        raise AlertError("alert transition events is invalid")
    for event in value["events"]:
        validate_event(event)
    _validate_active(value["activeState"])
    return value


def _same_canonical(path: Path, raw: bytes) -> bool:
    if not path.exists() and not path.is_symlink():
        return False
    current = common.read_regular(
        path,
        maximum=64 * 1024,
        expected_mode=0o600,
        require_root=True,
    )
    if current != raw:
        raise AlertError(f"existing alert evidence differs: {path}")
    return True


def _finish_transition(paths: dict[str, Path], transition: dict[str, Any]) -> None:
    for event in transition["events"]:
        raw = common.canonical_json(event)
        event_id = event["eventId"]
        pending = paths["pending"] / f"{event_id}.json"
        delivered = paths["delivered"] / f"{event_id}.json"
        if not _same_canonical(pending, raw) and not _same_canonical(delivered, raw):
            common.atomic_new(pending, raw, mode=0o600)
    common.atomic_replace(
        paths["active"], common.canonical_json(transition["activeState"]), mode=0o600
    )
    common.safe_unlink(paths["transition"])


def _recover_transition(paths: dict[str, Path]) -> None:
    if not paths["transition"].exists() and not paths["transition"].is_symlink():
        return
    _, value = _read_private_json(paths["transition"], maximum=1024 * 1024)
    transition = _validate_transition(value)
    _finish_transition(paths, transition)


def record_report(
    report_path: Path,
    source: str,
    state: Path,
    *,
    now: datetime | None = None,
) -> tuple[int, int]:
    paths = _prepare_state(state)
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    now_text = common.utc_text(current)
    with _Lock(paths["lock"]):
        _recover_transition(paths)
        report_raw, report_value = _read_private_json(report_path, maximum=1024 * 1024)
        report = validate_report(report_value, report_raw, source)
        report_sha = hashlib.sha256(report_raw).hexdigest()
        active = _load_active(paths["active"], now_text)
        prior_entries = active["entries"][source]
        current_issues = {item["code"]: item for item in report["issues"]}
        new_entries = json.loads(json.dumps(active["entries"]))
        events: list[dict[str, Any]] = []

        for code, current_issue in sorted(current_issues.items()):
            signature = _issue_signature(current_issue)
            prior = prior_entries.get(code)
            if prior is None or prior["state"] == "clear":
                entry = {
                    "state": "active",
                    "episodeId": secrets.token_hex(16),
                    "signature": signature,
                    "severity": current_issue["severity"],
                    "summary": current_issue["summary"],
                    "requiredAction": current_issue["requiredAction"],
                    "lastReportSha256": report_sha,
                    "lastChangedAtUtc": now_text,
                }
                events.append(
                    _event(
                        source=source,
                        kind="opened",
                        entry=entry,
                        code=code,
                        report_sha=report_sha,
                        now=current,
                    )
                )
            elif prior["signature"] != signature:
                entry = {
                    "state": "active",
                    "episodeId": prior["episodeId"],
                    "signature": signature,
                    "severity": current_issue["severity"],
                    "summary": current_issue["summary"],
                    "requiredAction": current_issue["requiredAction"],
                    "lastReportSha256": report_sha,
                    "lastChangedAtUtc": now_text,
                }
                events.append(
                    _event(
                        source=source,
                        kind="updated",
                        entry=entry,
                        code=code,
                        report_sha=report_sha,
                        now=current,
                    )
                )
            else:
                entry = dict(prior)
                entry["lastReportSha256"] = report_sha
            new_entries[source][code] = entry

        for code, prior in sorted(prior_entries.items()):
            if prior["state"] != "active" or code in current_issues:
                continue
            cleared = dict(prior)
            cleared["state"] = "clear"
            cleared["lastReportSha256"] = report_sha
            cleared["lastChangedAtUtc"] = now_text
            new_entries[source][code] = cleared
            events.append(
                _event(
                    source=source,
                    kind="recovered",
                    entry=cleared,
                    code=code,
                    report_sha=report_sha,
                    now=current,
                )
            )

        active_state = {
            "format": "uten-imp-monitor-active-alerts-v1",
            "entries": new_entries,
            "updatedAtUtc": now_text,
        }
        _validate_active(active_state)
        if not events:
            common.atomic_replace(
                paths["active"], common.canonical_json(active_state), mode=0o600
            )
            return 0, len(list(paths["pending"].glob("*.json")))

        event_bytes = [common.canonical_json(item) for item in events]
        _pending_capacity(paths, event_bytes)
        transition = {
            "format": "uten-imp-monitor-alert-transition-v1",
            "source": source,
            "reportSha256": report_sha,
            "events": events,
            "activeState": active_state,
        }
        common.atomic_new(
            paths["transition"], common.canonical_json(transition), mode=0o600
        )
        _finish_transition(paths, transition)
        return len(events), len(list(paths["pending"].glob("*.json")))


def _monitor_failure_event(unit: str, now: datetime) -> dict[str, Any]:
    if unit not in ALLOWED_FAILURE_UNITS:
        raise AlertError("unit is outside the monitor failure allowlist")
    source = "external" if "external" in unit else "host"
    return {
        "format": "uten-imp-monitor-alert-v1",
        "eventId": _event_id(now),
        "episodeId": secrets.token_hex(16),
        "source": source,
        "kind": "monitor-failed",
        "code": "monitor.execution-failed",
        "severity": "critical",
        "occurredAtUtc": common.utc_text(now),
        "summary": f"monitoring execution failed for {unit}; inspect the persistent journal",
        "requiredAction": "restore the monitor without bypassing its policy, then verify alert delivery",
        "reportSha256": "0" * 64,
        "containsSecrets": False,
    }


def emit_unit_failure(unit: str, state: Path, *, now: datetime | None = None) -> int:
    paths = _prepare_state(state)
    with _Lock(paths["lock"]):
        _recover_transition(paths)
        # Deduplicate only while an execution-failure event is still pending.
        # Once it is delivered, a later OnFailure is a new occurrence and must
        # page again; permanent deduplication against historical delivery would
        # silently suppress a second monitor outage.
        for event_path in paths["pending"].glob("*.json"):
            raw, value = _read_private_json(event_path)
            event = validate_event(value)
            if (
                event["kind"] == "monitor-failed"
                and event["summary"].startswith(f"monitoring execution failed for {unit}")
            ):
                return 0
        event = _monitor_failure_event(unit, now or datetime.now(timezone.utc))
        raw = common.canonical_json(event)
        _pending_capacity(paths, [raw])
        common.atomic_new(paths["pending"] / f"{event['eventId']}.json", raw)
        return 1


def validate_receipt(path: Path, event: dict[str, Any]) -> dict[str, Any]:
    _, value = _read_private_json(path)
    expected = {
        "schemaVersion",
        "eventId",
        "accepted",
        "deliveredAtUtc",
        "providerMessageId",
    }
    if not isinstance(value, dict) or set(value) != expected:
        raise AlertError("external alert receipt schema differs")
    if value["schemaVersion"] != 1 or value["eventId"] != event["eventId"]:
        raise AlertError("external alert receipt does not bind this event")
    if value["accepted"] is not True:
        raise AlertError("external alert receipt did not accept the event")
    occurred = common.parse_utc(event["occurredAtUtc"])
    delivered = common.parse_utc(value["deliveredAtUtc"])
    if delivered < occurred or delivered > datetime.now(timezone.utc):
        raise AlertError("external alert receipt time is not credible")
    if not isinstance(value["providerMessageId"], str) or not MESSAGE_ID.fullmatch(
        value["providerMessageId"]
    ):
        raise AlertError("external alert provider message ID is invalid")
    return value


def _quarantine(path: Path, paths: dict[str, Path], event_id: str) -> None:
    if not path.exists() and not path.is_symlink():
        return
    rejected = list(paths["rejected"].iterdir())
    if len(rejected) >= MAX_REJECTED_RECEIPTS:
        raise AlertError("rejected alert-receipt quota is full")
    destination = paths["rejected"] / f"{event_id}-{secrets.token_hex(16)}.json"
    os.replace(path, destination)
    common.fsync_directory(path.parent)
    common.fsync_directory(destination.parent)


def _complete_delivery(
    event_path: Path,
    paths: dict[str, Path],
    event: dict[str, Any],
    receipt_path: Path,
    *,
    final_exists: bool,
) -> None:
    receipt = validate_receipt(receipt_path, event)
    final_receipt = paths["receipts"] / f"{event['eventId']}.json"
    delivered = paths["delivered"] / f"{event['eventId']}.json"
    if delivered.exists() or delivered.is_symlink():
        raise AlertError("pending and delivered copies both exist")
    if final_exists:
        if receipt_path != final_receipt:
            raise AlertError("final receipt path differs")
    else:
        if final_receipt.exists() or final_receipt.is_symlink():
            raise AlertError("final receipt already exists unexpectedly")
        common.atomic_new(final_receipt, common.canonical_json(receipt))
    os.replace(event_path, delivered)
    common.fsync_directory(event_path.parent)
    common.fsync_directory(delivered.parent)


def deliver_event(
    event_path: Path,
    paths: dict[str, Path],
    sender: Path = FIXED_SENDER,
) -> bool:
    raw, value = _read_private_json(event_path)
    event = validate_event(value)
    original_digest = hashlib.sha256(raw).hexdigest()
    if _production() and sender != FIXED_SENDER:
        raise AlertError("production external alert sender path is fixed")
    if sender.exists() or sender.is_symlink():
        details = sender.lstat()
        if sender.is_symlink() or not stat.S_ISREG(details.st_mode):
            raise AlertError("external alert sender is not one regular file")
        if _production() and (
            details.st_uid != 0
            or details.st_nlink != 1
            or details.st_mode & 0o022
            or not details.st_mode & 0o100
        ):
            raise AlertError("external alert sender is not trusted root executable")
    else:
        return False

    final_receipt = paths["receipts"] / f"{event['eventId']}.json"
    work_receipt = paths["work"] / f"{event['eventId']}.receipt.json"
    if final_receipt.exists() or final_receipt.is_symlink():
        _complete_delivery(
            event_path, paths, event, final_receipt, final_exists=True
        )
        if work_receipt.exists() or work_receipt.is_symlink():
            _quarantine(work_receipt, paths, event["eventId"])
        return True
    if work_receipt.exists() or work_receipt.is_symlink():
        try:
            _complete_delivery(
                event_path, paths, event, work_receipt, final_exists=False
            )
        except (AlertError, OSError):
            _quarantine(work_receipt, paths, event["eventId"])
        else:
            common.safe_unlink(work_receipt)
            return True

    try:
        result = subprocess.run(
            [
                str(sender),
                "--event-file",
                str(event_path),
                "--receipt-file",
                str(work_receipt),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=common.SAFE_ENVIRONMENT,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    if result.returncode != 0 or not work_receipt.exists():
        _quarantine(work_receipt, paths, event["eventId"])
        return False
    if hashlib.sha256(
        common.read_regular(
            event_path,
            maximum=64 * 1024,
            expected_mode=0o600,
            require_root=True,
        )
    ).hexdigest() != original_digest:
        raise AlertError("pending alert changed while sender executed")
    try:
        _complete_delivery(event_path, paths, event, work_receipt, final_exists=False)
    except (AlertError, OSError):
        _quarantine(work_receipt, paths, event["eventId"])
        return False
    common.safe_unlink(work_receipt)
    return True


def drain(state: Path, sender: Path = FIXED_SENDER) -> tuple[int, int]:
    paths = _prepare_state(state)
    delivered_count = 0
    pending_count = 0
    with _Lock(paths["lock"]):
        _recover_transition(paths)
        events = sorted(paths["pending"].glob("*.json"))
        if len(events) > MAX_PENDING_EVENTS:
            raise AlertError("pending alert count exceeds quota")
        for event_path in events:
            if deliver_event(event_path, paths, sender):
                delivered_count += 1
            else:
                pending_count += 1
    return delivered_count, pending_count


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    record = sub.add_parser("record-report")
    record.add_argument("--source", required=True, choices=sorted(REPORT_FORMATS))
    record.add_argument("--report", type=Path, required=True)
    record.add_argument("--state", type=Path, default=DEFAULT_STATE)
    failure = sub.add_parser("unit-failure")
    failure.add_argument("--unit", required=True)
    failure.add_argument("--state", type=Path, default=DEFAULT_STATE)
    drain_parser = sub.add_parser("drain")
    drain_parser.add_argument("--state", type=Path, default=DEFAULT_STATE)
    return parser


def _validate_production_paths(args: argparse.Namespace) -> None:
    if not _production():
        return
    if os.name != "posix" or os.geteuid() != 0:
        raise AlertError("production monitoring alert spool requires root on POSIX")
    if args.state != DEFAULT_STATE:
        raise AlertError("production monitoring state path is fixed")
    if args.action == "record-report":
        expected = HOST_REPORT if args.source == "host" else EXTERNAL_REPORT
        if args.report != expected:
            raise AlertError("production monitoring report path is fixed")


def main() -> int:
    args = build_parser().parse_args()
    try:
        _validate_production_paths(args)
        if args.action == "record-report":
            created, pending = record_report(
                args.report, args.source, args.state
            )
            print(
                json.dumps(
                    {"status": "RECORDED", "created": created, "pending": pending},
                    sort_keys=True,
                )
            )
            return 0
        if args.action == "unit-failure":
            created = emit_unit_failure(args.unit, args.state)
            print(json.dumps({"status": "RECORDED", "created": created}))
            return 0
        delivered_count, pending_count = drain(args.state)
        print(
            json.dumps(
                {
                    "status": "PASS" if pending_count == 0 else "PENDING",
                    "delivered": delivered_count,
                    "pending": pending_count,
                },
                sort_keys=True,
            )
        )
        return 0 if pending_count == 0 else TEMPORARY_FAILURE
    except (AlertError, common.MonitoringError, OSError, ValueError) as exc:
        print(f"MONITOR_ALERT_ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
