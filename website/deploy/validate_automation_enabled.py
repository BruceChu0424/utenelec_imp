#!/usr/bin/env python3
"""Validate the durable commissioning receipt before scheduled website jobs."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import stat
import subprocess
import sys


CONTROL = Path("/var/lib/uten-website/control/commissioning")
MARKER = CONTROL / "automation-enabled.json"
IN_PROGRESS = CONTROL / "automation-in-progress.json"
PLAN = CONTROL / "automation-plan.json"
RECEIPTS = CONTROL / "receipts"
STAGE_OPT_IN = Path("/etc/uten-website/enable-auto-staging")
UNIT_PATHS = tuple(
    Path("/etc/systemd/system") / name
    for name in (
        "uten-website-backup.service",
        "uten-website-backup.timer",
        "uten-website-health.service",
        "uten-website-health.timer",
        "uten-website-stage.service",
        "uten-website-stage.timer",
    )
)
HELPER_PATHS = tuple(
    Path(value)
    for value in (
        "/usr/local/libexec/uten-website/uten-website-paired-backup",
        "/usr/local/libexec/uten-website/uten-website-health",
        "/usr/local/libexec/uten-website/validate-automation-enabled",
        "/usr/local/libexec/uten-website/validate-storage",
        "/usr/local/libexec/uten-website/paired_state.py",
        "/usr/local/libexec/uten-website/website_release.py",
        "/usr/local/libexec/uten-website/open_root_lock.py",
        "/usr/local/libexec/uten-website/uten-website-boot-guard",
    )
)


class CommissionError(RuntimeError):
    pass


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def checked_json(path: Path) -> tuple[bytes, dict[str, object]]:
    info = path.lstat()
    if (
        path.is_symlink()
        or not stat.S_ISREG(info.st_mode)
        or info.st_uid != 0
        or info.st_gid != 0
        or stat.S_IMODE(info.st_mode) != 0o600
        or info.st_nlink != 1
    ):
        raise CommissionError(f"unsafe root evidence: {path}")
    raw = path.read_bytes()
    value = json.loads(raw)
    if not isinstance(value, dict) or raw != canonical(value):
        raise CommissionError(f"non-canonical root evidence: {path}")
    return raw, value


def checked_digest(path: Path, expected_mode: int) -> str:
    info = path.lstat()
    if (
        path.is_symlink()
        or not stat.S_ISREG(info.st_mode)
        or info.st_uid != 0
        or info.st_gid != 0
        or stat.S_IMODE(info.st_mode) != expected_mode
        or info.st_nlink != 1
    ):
        raise CommissionError(f"unsafe commissioned executable/unit: {path}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def systemd_state(action: str, unit: str) -> str:
    result = subprocess.run(
        ["/usr/bin/systemctl", action, unit],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    return result.stdout.strip()


def validate() -> None:
    if IN_PROGRESS.exists() or IN_PROGRESS.is_symlink():
        raise CommissionError("automation commissioning is incomplete")
    _, marker = checked_json(MARKER)
    if set(marker) != {"format", "planSha256", "receipt", "receiptSha256"}:
        raise CommissionError("automation enabled marker contract differs")
    if marker.get("format") != "uten-website-automation-enabled-v1" or not re.fullmatch(
        r"[0-9a-f]{64}", str(marker.get("planSha256", ""))
    ):
        raise CommissionError("automation enabled marker value differs")
    plan_raw, plan = checked_json(PLAN)
    if hashlib.sha256(plan_raw).hexdigest() != marker["planSha256"]:
        raise CommissionError("commission plan digest differs from enabled marker")
    plan_keys = {
        "acceptanceSha256",
        "evidenceSha256",
        "executionSha256",
        "format",
        "restoreDrillReceipt",
        "restoreDrillReceiptSha256",
        "timerState",
        "unitSha256",
    }
    if set(plan) != plan_keys or plan.get("format") != "uten-website-automation-commission-plan-v1":
        raise CommissionError("commission plan contract differs")
    expected_initial_state = {
        "backup": {"active": "inactive", "enabled": "disabled"},
        "health": {"active": "inactive", "enabled": "disabled"},
        "stage": {"active": "inactive", "enabled": "disabled", "optIn": "absent"},
    }
    if plan.get("timerState") != expected_initial_state:
        raise CommissionError("commission plan did not start from all automation disabled")
    expected_units = {path.name: checked_digest(path, 0o644) for path in UNIT_PATHS}
    expected_helpers = {str(path): checked_digest(path, 0o755) for path in HELPER_PATHS}
    if plan.get("unitSha256") != expected_units:
        raise CommissionError("commissioned systemd unit bytes drifted")
    if plan.get("executionSha256") != expected_helpers:
        raise CommissionError("commissioned execution helper bytes drifted")
    if STAGE_OPT_IN.exists() or STAGE_OPT_IN.is_symlink():
        raise CommissionError("automatic staging opt-in must remain absent")
    expected_runtime_states = {
        ("is-enabled", "uten-website-backup.timer"): "enabled",
        ("is-active", "uten-website-backup.timer"): "active",
        ("is-enabled", "uten-website-health.timer"): "enabled",
        ("is-active", "uten-website-health.timer"): "active",
        ("is-enabled", "uten-website-stage.timer"): "disabled",
        ("is-active", "uten-website-stage.timer"): "inactive",
    }
    for (action, unit), expected_state in expected_runtime_states.items():
        if systemd_state(action, unit) != expected_state:
            raise CommissionError(f"{unit} {action} state differs from {expected_state}")
    receipt = Path(str(marker["receipt"]))
    if receipt.parent != RECEIPTS or not re.fullmatch(
        r"\d{8}T\d{6}Z-[0-9a-f]{64}\.json", receipt.name
    ):
        raise CommissionError("automation receipt path differs")
    receipt_raw, receipt_value = checked_json(receipt)
    if hashlib.sha256(receipt_raw).hexdigest() != marker.get("receiptSha256"):
        raise CommissionError("automation receipt digest differs")
    expected = {
        "backupTimer": "enabled-active",
        "format": "uten-website-automation-commission-receipt-v1",
        "healthTimer": "enabled-active",
        "planSha256": marker["planSha256"],
        "stageTimer": "disabled-inactive-opt-in-absent",
    }
    if receipt_value != expected:
        raise CommissionError("automation receipt content differs")


def main() -> int:
    try:
        if len(sys.argv) != 1:
            raise CommissionError("this fixed-path validator accepts no arguments")
        validate()
        print("WEBSITE_AUTOMATION_ENABLED_VERIFIED")
        return 0
    except (CommissionError, OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError) as exc:
        print(f"WEBSITE_AUTOMATION_ENABLED_REFUSED: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
