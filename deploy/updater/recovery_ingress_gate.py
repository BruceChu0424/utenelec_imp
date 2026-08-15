#!/usr/bin/env python3
"""Allow recovery ingress probes only while the root recovery lock is held."""

from __future__ import annotations

import fcntl
import grp
import hashlib
import json
import os
import re
import stat
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path("/var/lib/uten-imp-release")
PENDING = ROOT / "recovery-ingress-pending.json"
AUTHORIZATION = ROOT / "recovery-ingress-authorization.json"
FINALIZING = ROOT / "recovery-ingress-finalizing.json"
OPERATION_LOCK = ROOT / "operation.lock"
BOOT_ID = Path("/proc/sys/kernel/random/boot_id")
EVIDENCE = ROOT / "recovery-evidence"
MAX_JSON = 256 * 1024
MAX_AGE_SECONDS = 300
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
BOOT_ID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
)
TRANSACTION_RE = re.compile(r"^[0-9a-f]{16}-[A-Za-z0-9_-]+$")
UTC_RE = re.compile(r"^20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z$")


class GateError(RuntimeError):
    pass


def strict(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    try:
        details = path.lstat()
    except OSError as exc:
        raise GateError(f"missing {label}") from exc
    if (
        not stat.S_ISREG(details.st_mode)
        or path.is_symlink()
        or details.st_uid != 0
        or details.st_gid != 0
        or stat.S_IMODE(details.st_mode) != 0o600
        or details.st_nlink != 1
        or not 1 <= details.st_size <= MAX_JSON
    ):
        raise GateError(f"unsafe {label}")
    raw = path.read_bytes()

    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in items:
            if key in value:
                raise GateError(f"duplicate key in {label}")
            value[key] = item
        return value

    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(
                GateError(f"non-finite value in {label}: {token}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise GateError(f"invalid {label}") from exc
    if not isinstance(value, dict):
        raise GateError(f"non-object {label}")
    return value, raw


def parse_utc(value: Any) -> datetime:
    if not isinstance(value, str) or UTC_RE.fullmatch(value) is None:
        raise GateError("invalid recovery probe authorization timestamp")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as exc:
        raise GateError("invalid recovery probe authorization timestamp") from exc


def validate_pending(value: dict[str, Any], raw: bytes) -> Path:
    if set(value) != {
        "action",
        "commitSha256",
        "markerSha256",
        "planSha256",
        "schemaVersion",
        "status",
        "targetVersion",
        "transactionDirectory",
    } or value.get("schemaVersion") != 1 or value.get("status") != "RECOVERY_COMMITTED_PENDING_INGRESS":
        raise GateError("recovery ingress pending schema differs")
    for key in ("commitSha256", "markerSha256", "planSha256"):
        if not isinstance(value.get(key), str) or SHA256_RE.fullmatch(value[key]) is None:
            raise GateError(f"invalid pending {key}")
    transaction = Path(str(value.get("transactionDirectory", "")))
    if (
        transaction.parent != EVIDENCE
        or TRANSACTION_RE.fullmatch(transaction.name) is None
        or not transaction.name.startswith(value["planSha256"][:16] + "-")
    ):
        raise GateError("recovery transaction escaped its evidence root")
    if hashlib.sha256(raw).hexdigest() == "":  # pragma: no cover - defensive
        raise GateError("unhashable recovery pending gate")
    return transaction


def validate_finalizing_before_listen() -> None:
    value, _raw = strict(FINALIZING, "recovery ingress finalization")
    if set(value) != {
        "action", "commitSha256", "markerSha256", "pendingSha256",
        "planSha256", "schemaVersion", "status", "targetVersion",
        "transactionDirectory",
    } or value.get("schemaVersion") != 1 or value.get("status") != (
        "RECOVERY_INGRESS_DURABLY_AUTHORIZED_PENDING_PROBES"
    ):
        raise GateError("recovery ingress finalization schema differs")
    for key in ("commitSha256", "markerSha256", "pendingSha256", "planSha256"):
        if not isinstance(value.get(key), str) or SHA256_RE.fullmatch(value[key]) is None:
            raise GateError(f"invalid finalizing {key}")
    transaction = Path(str(value.get("transactionDirectory", "")))
    if (
        transaction.parent != EVIDENCE
        or TRANSACTION_RE.fullmatch(transaction.name) is None
        or not transaction.name.startswith(value["planSha256"][:16] + "-")
    ):
        raise GateError("recovery finalization escaped its evidence root")
    pending, pending_raw = strict(
        transaction / "recovery-ingress-pending.committed.json",
        "archived recovery ingress pending gate",
    )
    if hashlib.sha256(pending_raw).hexdigest() != value["pendingSha256"]:
        raise GateError("archived recovery ingress pending digest changed")
    validate_pending(pending, pending_raw)
    for key in (
        "action", "commitSha256", "markerSha256", "planSha256",
        "targetVersion", "transactionDirectory",
    ):
        if pending.get(key) != value.get(key):
            raise GateError("recovery finalization differs from archived pending")
    commit, commit_raw = strict(transaction / "recovery-commit.json", "recovery commit")
    if hashlib.sha256(commit_raw).hexdigest() != value["commitSha256"]:
        raise GateError("recovery finalization commit digest changed")
    if any(commit.get(key) != value.get(key) for key in (
        "action", "markerSha256", "planSha256", "targetVersion", "transactionDirectory"
    )):
        raise GateError("recovery finalization commit identity differs")


def process_start_time_ticks(pid: int) -> int:
    try:
        raw = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
        _prefix, separator, suffix = raw.rpartition(") ")
        fields = suffix.split()
        if not separator or len(fields) <= 19:
            raise GateError("cannot parse recovery authorization issuer")
        value = int(fields[19])
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise GateError("cannot read recovery authorization issuer") from exc
    if value <= 0:
        raise GateError("invalid recovery authorization issuer")
    return value


def validate_issuer_identity(value: dict[str, Any]) -> int:
    issuer_pid = value.get("issuerPid")
    issuer_start = value.get("issuerStartTimeTicks")
    if (
        not isinstance(issuer_pid, int)
        or isinstance(issuer_pid, bool)
        or issuer_pid <= 1
        or not isinstance(issuer_start, int)
        or isinstance(issuer_start, bool)
        or issuer_start <= 0
        or process_start_time_ticks(issuer_pid) != issuer_start
    ):
        raise GateError("recovery probe authorization issuer changed")
    try:
        executable = Path(f"/proc/{issuer_pid}/exe").resolve(strict=True)
        command_line = Path(f"/proc/{issuer_pid}/cmdline").read_bytes()
        executable_sha = hashlib.sha256(executable.read_bytes()).hexdigest()
    except OSError as exc:
        raise GateError("cannot inspect recovery authorization issuer") from exc
    if (
        executable.parent != Path("/usr/bin")
        or not executable.name.startswith("python3")
        or value.get("issuerExecutablePath") != str(executable)
        or value.get("issuerExecutableSha256") != executable_sha
        or value.get("issuerCommandLineSha256")
        != hashlib.sha256(command_line).hexdigest()
    ):
        raise GateError("recovery authorization issuer executable changed")
    return issuer_pid


def operation_lock_is_held_by(issuer_pid: int) -> None:
    try:
        updater_gid = grp.getgrnam("uten-imp-updater").gr_gid
        descriptor = os.open(
            OPERATION_LOCK,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
    except (KeyError, OSError) as exc:
        raise GateError("cannot open the fixed release operation lock") from exc
    try:
        details = os.fstat(descriptor)
        if (
            not stat.S_ISREG(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != updater_gid
            or stat.S_IMODE(details.st_mode) != 0o660
            or details.st_nlink != 1
        ):
            raise GateError("unsafe release operation lock")
        device = f"{os.major(details.st_dev):02x}:{os.minor(details.st_dev):02x}"
        inode = str(details.st_ino)
        try:
            locks = Path("/proc/locks").read_text(encoding="ascii").splitlines()
        except (OSError, UnicodeDecodeError) as exc:
            raise GateError("cannot inspect the recovery operation lock owner") from exc
        for line in locks:
            fields = line.split()
            if len(fields) < 6 or fields[1:4] != ["FLOCK", "ADVISORY", "WRITE"]:
                continue
            try:
                owner_pid = int(fields[4])
                lock_device, lock_inode = fields[5].rsplit(":", 1)
            except (ValueError, TypeError):
                continue
            if (
                owner_pid == issuer_pid
                and lock_device.lower() == device.lower()
                and lock_inode == inode
            ):
                return
        raise GateError("recovery operation lock is not held by its issuer")
    finally:
        os.close(descriptor)


def verify() -> None:
    pending_exists = os.path.lexists(PENDING)
    authorization_exists = os.path.lexists(AUTHORIZATION)
    if not pending_exists:
        if authorization_exists:
            raise GateError("orphaned recovery probe authorization exists")
        if os.path.lexists(FINALIZING):
            validate_finalizing_before_listen()
        return
    if os.path.lexists(FINALIZING):
        raise GateError("live pending and durable finalization coexist")
    pending, pending_raw = strict(PENDING, "recovery ingress pending gate")
    transaction = validate_pending(pending, pending_raw)
    authorization, _authorization_raw = strict(
        AUTHORIZATION, "recovery ingress probe authorization"
    )
    if set(authorization) != {
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
    } or authorization.get("schemaVersion") != 1 or authorization.get("status") != "RECOVERY_INGRESS_PROBE_AUTHORIZED":
        raise GateError("recovery probe authorization schema differs")
    boot_id = BOOT_ID.read_text(encoding="ascii").strip()
    if BOOT_ID_RE.fullmatch(boot_id) is None or authorization.get("bootId") != boot_id:
        raise GateError("recovery probe authorization belongs to another boot")
    if authorization.get("transactionDirectory") != str(transaction):
        raise GateError("recovery probe authorization names another transaction")
    for key in ("issuerCommandLineSha256", "issuerExecutableSha256"):
        if not isinstance(authorization.get(key), str) or SHA256_RE.fullmatch(
            authorization[key]
        ) is None:
            raise GateError(f"invalid recovery authorization {key}")
    if (
        not isinstance(authorization.get("issuerExecutablePath"), str)
        or not authorization["issuerExecutablePath"].startswith("/usr/bin/python3")
    ):
        raise GateError("invalid recovery authorization executable path")
    issuer_pid = validate_issuer_identity(authorization)
    expected_pending_sha = hashlib.sha256(pending_raw).hexdigest()
    if authorization.get("pendingSha256") != expected_pending_sha:
        raise GateError("recovery probe authorization names another pending gate")
    age = (datetime.now(timezone.utc) - parse_utc(authorization.get("issuedAtUtc"))).total_seconds()
    if age < -5 or age > MAX_AGE_SECONDS:
        raise GateError("recovery probe authorization is outside its bounded window")
    operation_lock_is_held_by(issuer_pid)


def main() -> int:
    if len(sys.argv) != 1 or os.geteuid() != 0:
        return 2
    try:
        verify()
        return 0
    except (GateError, OSError) as exc:
        print(f"RECOVERY_INGRESS_NO_GO: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
