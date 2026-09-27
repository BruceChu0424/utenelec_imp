#!/usr/bin/env python3
"""Evaluate the database update schedule locally; only due slots contact OSS."""

from __future__ import annotations

import datetime as dt
import fcntl
import grp
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
from zoneinfo import ZoneInfo


SETTING_KEY = "updater_check_interval_days"
STATE_DIR = Path("/var/lib/uten-imp-update-schedule")
STATUS_PATH = Path("/var/lib/uten-imp/updater-schedule/status.json")
UPDATER = "/usr/local/sbin/uten-imp-updater"
CONFIG_SQL = """SELECT json_build_object('intervalDays', value,
    'updatedAt', updated_at) FROM public.system_settings
    WHERE key = 'updater_check_interval_days';"""


def timestamp(value: dt.datetime | None) -> str | None:
    return value.isoformat() if value is not None else None


def parse_timestamp(value: str) -> dt.datetime:
    if not isinstance(value, str):
        raise ValueError("invalid timestamp")
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp has no timezone")
    return parsed


def parse_config(raw: dict) -> tuple[int, dt.datetime]:
    if not isinstance(raw, dict):
        raise ValueError("invalid configuration")
    value = raw["intervalDays"]
    if not isinstance(value, str) or not re.fullmatch(r"[+-]?[0-9]+", value):
        raise ValueError("invalid interval")
    interval = int(value)
    if not 0 <= interval <= 365:
        raise ValueError("invalid interval")
    return interval, parse_timestamp(raw["updatedAt"])


def read_config() -> dict:
    # Fixed host, role, SQL and argv. No application-controlled command or shell.
    result = subprocess.run(
        ["/usr/sbin/runuser", "-u", "postgres", "--", "/usr/bin/psql",
         "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-h", "/var/run/postgresql",
         "-p", "5432", "-U", "postgres", "-d", "uten_imp", "-c", CONFIG_SQL],
        env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PGCONNECT_TIMEOUT": "3",
             "PGOPTIONS": "-c default_transaction_read_only=on -c statement_timeout=5000",
             "PGAPPNAME": "uten-imp-update-schedule"},
        check=True, capture_output=True, text=True, timeout=10,
    )
    return json.loads(result.stdout)


def scheduled_slots(interval: int, updated: dt.datetime, now: dt.datetime,
                    zone: dt.tzinfo) -> tuple[dt.datetime | None, dt.datetime | None]:
    """Return today's due slot and the strictly future slot; never catch up yesterday."""
    if interval == 0:
        return None, None
    local_now = now.astimezone(zone)
    local_updated = updated.astimezone(zone)

    def at_five(day: dt.date) -> dt.datetime:
        return dt.datetime.combine(day, dt.time(5), zone)

    if interval == 7:
        first = at_five(local_updated.date() + dt.timedelta(days=(6 - local_updated.weekday()) % 7))
        if first <= local_updated:
            first += dt.timedelta(days=7)
    else:
        first = at_five(local_updated.date() + dt.timedelta(days=interval))
    if local_now < first:
        return None, first
    elapsed_days = (local_now.date() - first.date()).days
    latest = at_five(first.date() + dt.timedelta(days=(elapsed_days // interval) * interval))
    due = latest if latest.date() == local_now.date() and latest <= local_now else None
    future = latest if latest > local_now else at_five(latest.date() + dt.timedelta(days=interval))
    return due, future


def atomic_json(path: Path, payload: dict, mode: int, gid: int) -> None:
    fd, temporary = tempfile.mkstemp(prefix=".schedule-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            os.fchmod(output.fileno(), mode)
            os.fchown(output.fileno(), -1, gid)
            json.dump(payload, output, ensure_ascii=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def private_state(path: Path) -> dict:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return {"lastAttemptAt": None, "lastResult": "NEVER", "error": None}
    with os.fdopen(fd, encoding="utf-8") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError("unsafe state file")
        result = json.load(source)
    if not isinstance(result, dict) or result.get("lastResult") not in {"NEVER", "RUNNING", "SUCCESS", "FAILED"}:
        raise ValueError("invalid state")
    if result.get("lastAttemptAt") is not None:
        parse_timestamp(result["lastAttemptAt"])
    return result


def run_check() -> int:
    # Existing updater retains its own activation lock, signature and migration gates.
    return subprocess.run([UPDATER, "check"], check=False).returncode


def tick(now: dt.datetime, zone: dt.tzinfo, state_dir: Path, status_path: Path,
         status_gid: int, reader=read_config, checker=run_check) -> dict:
    state_path = state_dir / "attempt.json"
    lock_fd = os.open(state_dir / "schedule.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {"busy": True}
        receipt = {"schemaVersion": 1, "checkedAt": timestamp(now),
                   "appliedIntervalDays": None, "configUpdatedAt": None, "nextCheckAt": None,
                   "lastAttemptAt": None, "lastResult": "NEVER", "error": None}

        def publish() -> None:
            atomic_json(status_path, receipt, 0o640, status_gid)

        try:
            state = private_state(state_path)
        except (OSError, ValueError, TypeError, KeyError):
            receipt["error"] = "Automatic update state is invalid; manual inspection is required."
            publish()
            return receipt
        if state["lastResult"] == "RUNNING":
            state["lastResult"] = "FAILED"
            state["error"] = "Previous automatic check did not record completion; retry manually."
            atomic_json(state_path, state, 0o600, os.getgid())
        receipt.update({key: state.get(key) for key in ("lastAttemptAt", "lastResult", "error")})
        try:
            raw = reader()
        except (OSError, ValueError, subprocess.SubprocessError):
            receipt["error"] = "Could not read the local database update schedule; OSS was not contacted."
            publish()
            return receipt
        try:
            interval, updated = parse_config(raw)
            due, future = scheduled_slots(interval, updated, now, zone)
        except (ValueError, TypeError, KeyError, OverflowError):
            receipt["error"] = "The local database update schedule is invalid; OSS was not contacted."
            publish()
            return receipt
        receipt.update(appliedIntervalDays=interval, configUpdatedAt=timestamp(updated),
                       nextCheckAt=timestamp(future))
        last_attempt = parse_timestamp(state["lastAttemptAt"]) if state.get("lastAttemptAt") else None
        already_attempted = last_attempt and last_attempt.astimezone(zone).date() >= now.astimezone(zone).date()
        if due is None or already_attempted:
            publish()
            return receipt
        # Persist BEFORE any network request. A failed/crashed attempt never loops on OSS.
        state = {"lastAttemptAt": timestamp(now), "lastResult": "RUNNING", "error": None}
        atomic_json(state_path, state, 0o600, os.getgid())
        receipt.update(state)
        publish()
        try:
            result = checker()
            state["lastResult"] = "SUCCESS" if result == 0 else "FAILED"
            state["error"] = None if result == 0 else "Automatic update check failed; inspect the updater journal."
        except (OSError, subprocess.SubprocessError):
            state["lastResult"] = "FAILED"
            state["error"] = "Automatic update check could not complete; inspect the updater journal."
        atomic_json(state_path, state, 0o600, os.getgid())
        receipt.update(state)
        publish()
        return receipt


def secure_directory(path: Path, mode: int, gid: int) -> None:
    path.mkdir(mode=mode, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise RuntimeError("schedule directory is not controlled by root")
    os.chown(path, 0, gid)
    os.chmod(path, mode)


def main() -> int:
    if os.geteuid() != 0:
        raise SystemExit("The local update scheduler must run as root.")
    status_gid = grp.getgrnam("uten-imp").gr_gid
    secure_directory(STATE_DIR, 0o700, 0)
    secure_directory(STATUS_PATH.parent.parent, 0o755, 0)
    secure_directory(STATUS_PATH.parent, 0o750, status_gid)
    with open("/etc/localtime", "rb") as localtime:
        zone = ZoneInfo.from_file(localtime, key="server-local")
    receipt = tick(dt.datetime.now(zone), zone, STATE_DIR, STATUS_PATH, status_gid)
    if receipt.get("error"):
        print(receipt["error"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
