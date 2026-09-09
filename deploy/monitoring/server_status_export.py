#!/usr/bin/env python3
"""Export a minimal read-only backup summary for ERP; never start a backup or contact storage."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import secrets
import stat

MAX_BYTES = 65536


def instant(value: str) -> datetime:
    if not isinstance(value, str):
        raise ValueError("Timestamp must be text")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Timestamp has no time zone")
    return parsed.astimezone(timezone.utc)


def summarize(report: dict, previous: dict | None = None) -> dict:
    if report.get("schemaVersion") != 1 or report.get("status") not in {"PASS", "FAIL"}:
        raise ValueError("Unrecognized backup health report")
    checked = instant(report["checkedAtUtc"])
    result = {"format": "uten-server-backup-status-v1", "sampledAt": checked.isoformat(),
              "lastSuccessAt": None, "lastAttemptStatus": "UNKNOWN"}
    if report["status"] == "FAIL":
        # A failed health check is different from a failed backup job. Do not
        # publish its potentially sensitive raw exception or database identity.
        result["lastAttemptStatus"] = "CHECK_FAILED"
        if previous and previous.get("format") == result["format"] and previous.get("lastSuccessAt"):
            success = instant(previous["lastSuccessAt"])
            if success <= checked:
                result["lastSuccessAt"] = success.isoformat()
        return result
    repositories = report.get("repositories", [])
    if not isinstance(repositories, list) or any(not isinstance(repo, dict) for repo in repositories):
        raise ValueError("Invalid backup repositories")
    local = [repo for repo in repositories if repo.get("repo") == 1]
    if len(local) != 1:
        raise ValueError("Local repository identity is missing or ambiguous")
    stop = local[0].get("latestSuccessfulFullStopEpoch")
    if not isinstance(stop, int) or isinstance(stop, bool) or stop <= 0:
        raise ValueError("Missing completed backup timestamp")
    success = datetime.fromtimestamp(stop, timezone.utc)
    if success > checked:
        raise ValueError("Backup completion is after its check")
    result.update(lastSuccessAt=success.isoformat(), lastAttemptStatus="SUCCESS")
    # Preserve the source check time. Re-exporting an old report cannot make it fresh.
    return result


def summarize_pair(pg: dict | None, paired: dict | None, observed: datetime) -> dict:
    """Observe daily task evidence without pretending its completion is a health poll."""
    observed = observed.astimezone(timezone.utc)
    result = {"format": "uten-server-backup-status-v1", "sampledAt": observed.isoformat(),
              "lastSuccessAt": None, "lastAttemptStatus": "UNKNOWN", "reason": "STATUS_UNAVAILABLE"}
    pg_status, pg_success, pg_fresh = "UNKNOWN", None, False
    if pg is not None:
        try:
            if pg["format"] != result["format"]:
                raise ValueError("Unknown PG summary")
            checked = instant(pg["sampledAt"])
            pg_fresh = -120 <= (observed - checked).total_seconds() <= 900
            pg_status = pg["lastAttemptStatus"]
            if pg.get("lastSuccessAt"):
                pg_success = instant(pg["lastSuccessAt"])
                if pg_success > checked:
                    raise ValueError("Impossible PG success time")
        except (ValueError, KeyError, TypeError, OverflowError):
            pg_status, pg_success, pg_fresh = "UNKNOWN", None, False

    paired_status, paired_success = "UNKNOWN", None
    paired_reason = "PAIRED_NOT_CONFIGURED_OR_UNAVAILABLE"
    if paired is not None:
        try:
            if (paired["format"] != "uten-paired-backup-attempt-v1"
                    or paired["status"] not in {"RUNNING", "SUCCESS", "FAILED"}):
                raise ValueError("Unknown paired task status")
            started = instant(paired["startedAt"])
            completed = instant(paired["completedAt"]) if paired.get("completedAt") else None
            if started > observed or (completed is not None and (completed < started or completed > observed)):
                raise ValueError("Impossible paired attempt time")
            if paired.get("lastSuccessAt"):
                paired_success = instant(paired["lastSuccessAt"])
                if paired_success > (completed or started):
                    raise ValueError("Impossible paired success time")
            paired_status = paired["status"]
            if paired_status == "SUCCESS" and (completed is None or paired_success is None):
                raise ValueError("Successful paired task lacks completion evidence")
            if paired_status == "FAILED" and completed is None:
                raise ValueError("Failed paired task lacks completion time")
            paired_reason = "PAIRED_RUNNING" if paired_status == "RUNNING" else "PAIRED_STATUS_VALID"
        except (ValueError, KeyError, TypeError, OverflowError):
            paired_status, paired_success = "UNKNOWN", None
            paired_reason = "PAIRED_STATUS_INVALID"

    if pg_success is not None and paired_success is not None:
        result["lastSuccessAt"] = min(pg_success, paired_success).isoformat()
    if paired_status == "FAILED" or pg_status == "FAILED":
        result.update(lastAttemptStatus="FAILED", reason="BACKUP_TASK_FAILED")
    elif pg_status == "CHECK_FAILED" and pg_fresh:
        result.update(lastAttemptStatus="CHECK_FAILED", reason="PG_HEALTH_CHECK_FAILED")
    elif not pg_fresh or pg_status != "SUCCESS":
        result["reason"] = "PG_HEALTH_STALE_OR_UNAVAILABLE"
    elif paired_status != "SUCCESS":
        result["reason"] = paired_reason
    elif result["lastSuccessAt"] is None:
        result["reason"] = "COMPLETE_BACKUP_SUCCESS_NOT_PROVEN"
    else:
        result.update(lastAttemptStatus="SUCCESS", reason="PG_AND_PAIRED_VERIFIED")
    return result


def read_report(path: Path) -> dict:
    if not path.is_absolute():
        raise ValueError("Report path must be absolute")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("Report must be a regular file")
        raw = stream.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError("Report exceeds the bounded summary size")
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("Report must be an object")
    return value


def publish(path: Path, summary: dict) -> None:
    if not path.is_absolute():
        raise ValueError("Output must be absolute")
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    name = ".backup-summary-" + secrets.token_hex(8)
    try:
        descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o640, dir_fd=parent)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(json.dumps(summary, sort_keys=True, separators=(",", ":")).encode())
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path.name, src_dir_fd=parent, dst_dir_fd=parent)
        os.fsync(parent)
    finally:
        try:
            os.unlink(name, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("/var/lib/uten-imp-backup-health/health.json"))
    parser.add_argument("--output", type=Path, default=Path("/var/lib/uten-imp-server-status/backup.json"))
    parser.add_argument("--paired-source", type=Path,
                        default=Path("/data/uten-imp-backups/paired/last-attempt.json"))
    args = parser.parse_args()
    previous = None
    try:
        previous = read_report(args.output)
    except (OSError, ValueError):
        pass
    try:
        pg_summary = summarize(read_report(args.source), previous)
    except (OSError, ValueError, KeyError, TypeError, OverflowError):
        pg_summary = None
    try:
        paired_summary = read_report(args.paired_source)
    except (OSError, ValueError, KeyError, TypeError, OverflowError):
        paired_summary = None
    summary = summarize_pair(pg_summary, paired_summary, datetime.now(timezone.utc))
    publish(args.output, summary)


if __name__ == "__main__":
    main()
