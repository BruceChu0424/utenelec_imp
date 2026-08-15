#!/usr/bin/env python3
"""Secret-free HTTPS availability probe intended for an independent host.

Running this on the application host can detect DNS/TLS/edge drift, but cannot
prove host-loss availability.  Production acceptance therefore deploys it in a
separate failure domain (and through the company VPN for ERP) with the same
durable receipt-bound alert spool.  It never follows redirects or authenticates
as a business user.
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import re
import ssl
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlsplit


try:
    common = sys.modules["uten_imp_monitoring_common"]
    alert_spool = sys.modules["uten_imp_monitoring_alert_spool"]
except KeyError as exc:  # pragma: no cover - launcher/contract tests exercise it.
    raise RuntimeError(
        "external monitor must be executed through monitor_runtime_launcher.py"
    ) from exc


DEFAULT_POLICY = Path("/etc/uten-imp-monitoring/external-policy.json")
DEFAULT_STATE = Path("/var/lib/uten-imp-monitoring")
DEFAULT_REPORT = DEFAULT_STATE / "external-latest.json"
BOOT_ID = Path("/proc/sys/kernel/random/boot_id")
HOSTNAME = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"
)


class ExternalProbeError(common.MonitoringError):
    """External probe policy or HTTPS observation error."""


def _exact_dict(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ExternalProbeError(f"{label} schema differs")
    return value


def _integer(value: Any, label: str, minimum: int, maximum: int) -> int:
    if (
        not isinstance(value, int)
        or isinstance(value, bool)
        or value < minimum
        or value > maximum
    ):
        raise ExternalProbeError(f"{label} is outside the accepted range")
    return value


def validate_policy(value: Any) -> dict[str, Any]:
    policy = _exact_dict(value, {"format", "checks"}, "external monitor policy")
    if policy["format"] != "uten-imp-external-monitor-policy-v1":
        raise ExternalProbeError("external monitor policy format differs")
    checks = policy["checks"]
    if not isinstance(checks, list) or not 1 <= len(checks) <= 32:
        raise ExternalProbeError("external check list is empty or excessive")
    names: set[str] = set()
    for value in checks:
        check = _exact_dict(
            value,
            {
                "name",
                "url",
                "timeoutSeconds",
                "expectedStatus",
                "maximumBodyBytes",
                "bodyContract",
                "certificateWarningDays",
                "certificateCriticalDays",
            },
            "external check",
        )
        name = check["name"]
        if (
            not isinstance(name, str)
            or not common.ISSUE_CODE.fullmatch(name)
            or name in names
        ):
            raise ExternalProbeError("external check name is invalid or duplicated")
        names.add(name)
        if not isinstance(check["url"], str):
            raise ExternalProbeError("external URL is not a string")
        parsed = urlsplit(check["url"])
        if (
            parsed.scheme != "https"
            or parsed.username is not None
            or parsed.password is not None
            or parsed.port not in {None, 443}
            or not parsed.hostname
            or parsed.hostname != parsed.hostname.lower()
            or not HOSTNAME.fullmatch(parsed.hostname)
            or parsed.query
            or parsed.fragment
            or not parsed.path.startswith("/")
            or "//" in parsed.path
            or any(part in {".", ".."} for part in parsed.path.split("/"))
        ):
            raise ExternalProbeError("external URL is not a fixed credential-free HTTPS endpoint")
        _integer(check["timeoutSeconds"], "external timeout", 1, 30)
        _integer(check["expectedStatus"], "external HTTP status", 100, 599)
        _integer(check["maximumBodyBytes"], "external body limit", 1, 1024 * 1024)
        warning = _integer(
            check["certificateWarningDays"], "external certificate warning days", 7, 120
        )
        critical = _integer(
            check["certificateCriticalDays"], "external certificate critical days", 1, 60
        )
        if critical >= warning:
            raise ExternalProbeError("external certificate critical threshold must precede warning")
        contract = _exact_dict(
            check["bodyContract"], {"type", "value"}, "external body contract"
        )
        if contract["type"] == "json-status":
            if contract["value"] not in {"UP", "ok"}:
                raise ExternalProbeError("external JSON status value is unsupported")
        elif contract["type"] == "contains":
            if (
                not isinstance(contract["value"], str)
                or not 1 <= len(contract["value"]) <= 128
                or any(ord(character) < 0x20 for character in contract["value"])
            ):
                raise ExternalProbeError("external body marker is invalid")
        else:
            raise ExternalProbeError("external body contract type is unsupported")
    return policy


def load_policy(path: Path) -> tuple[bytes, dict[str, Any]]:
    raw, value = common.read_json_file(
        path,
        canonical=True,
        expected_mode=0o644,
        require_root=True,
    )
    return raw, validate_policy(value)


def _certificate_expiry_epoch(certificate: dict[str, Any]) -> float:
    not_after = certificate.get("notAfter")
    if not isinstance(not_after, str):
        raise ExternalProbeError("peer certificate has no notAfter")
    try:
        return ssl.cert_time_to_seconds(not_after)
    except (ValueError, OverflowError) as exc:
        raise ExternalProbeError("peer certificate notAfter is invalid") from exc


def https_check(
    check: dict[str, Any],
    *,
    now: datetime | None = None,
    connection_factory: Callable[..., Any] = http.client.HTTPSConnection,
) -> tuple[dict[str, Any], list[dict[str, str]]]:
    parsed = urlsplit(check["url"])
    assert parsed.hostname is not None
    context = ssl.create_default_context()
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    connection = connection_factory(
        parsed.hostname,
        443,
        timeout=check["timeoutSeconds"],
        context=context,
    )
    issues: list[dict[str, str]] = []
    try:
        connection.connect()
        if connection.sock is None:
            raise ExternalProbeError("TLS connection has no socket")
        peer = connection.sock.getpeercert()
        if not isinstance(peer, dict) or not peer:
            raise ExternalProbeError("TLS peer certificate is unavailable")
        expiry = _certificate_expiry_epoch(peer)
        cipher = connection.sock.cipher()
        tls_version = connection.sock.version()
        connection.request(
            "GET",
            parsed.path or "/",
            headers={
                "Accept": "application/json,text/html;q=0.8",
                "Connection": "close",
                "User-Agent": "uten-independent-availability-probe/1",
            },
        )
        response = connection.getresponse()
        body = response.read(check["maximumBodyBytes"] + 1)
        if len(body) > check["maximumBodyBytes"]:
            raise ExternalProbeError("HTTPS response body exceeds policy")
        if response.status != check["expectedStatus"]:
            issues.append(
                common.issue(
                    f"external.{check['name']}-status",
                    "critical",
                    f"{check['name']} returned HTTP {response.status} instead of the approved status",
                    "investigate DNS/TLS/edge and origin health from an independent path",
                )
            )
        contract = check["bodyContract"]
        body_ok = False
        if contract["type"] == "json-status":
            try:
                value = json.loads(body.decode("utf-8"))
                body_ok = isinstance(value, dict) and value.get("status") == contract["value"]
            except (UnicodeDecodeError, json.JSONDecodeError):
                body_ok = False
        else:
            body_ok = contract["value"].encode("utf-8") in body
        if not body_ok:
            issues.append(
                common.issue(
                    f"external.{check['name']}-body",
                    "critical",
                    f"{check['name']} response did not satisfy the approved body contract",
                    "check the real origin response; do not accept an SPA or proxy error page as health",
                )
            )
        current = (now or datetime.now(timezone.utc)).timestamp()
        remaining_days = (expiry - current) / 86400
        if remaining_days <= check["certificateCriticalDays"]:
            issues.append(
                common.issue(
                    f"external.{check['name']}-certificate",
                    "critical",
                    f"{check['name']} served certificate is expired or in the critical window",
                    "use the approved certificate provider and validate rollback before changing the edge",
                )
            )
        elif remaining_days <= check["certificateWarningDays"]:
            issues.append(
                common.issue(
                    f"external.{check['name']}-certificate",
                    "warning",
                    f"{check['name']} served certificate is in the renewal warning window",
                    "verify the already-approved renewal job and external chain before expiry",
                )
            )
        sans = sorted(
            str(value)
            for kind, value in peer.get("subjectAltName", [])
            if kind == "DNS"
        )
        return {
            "name": check["name"],
            "url": check["url"],
            "httpStatus": response.status,
            "bodyContractPassed": body_ok,
            "bodySha256": hashlib.sha256(body).hexdigest(),
            "remainingCertificateDays": round(remaining_days, 3),
            "peerSanSetSha256": hashlib.sha256("\n".join(sans).encode("utf-8")).hexdigest(),
            "tlsVersion": tls_version,
            "cipher": cipher[0] if cipher else None,
        }, issues
    finally:
        connection.close()


def _boot_id() -> str:
    if common.test_mode() and not BOOT_ID.exists():
        return "test-boot"
    value = BOOT_ID.read_text(encoding="ascii").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value):
        raise ExternalProbeError("kernel boot ID is invalid")
    return value


def collect_report(
    policy_raw: bytes,
    policy: dict[str, Any],
    *,
    now: datetime | None = None,
    probe: Callable[..., tuple[dict[str, Any], list[dict[str, str]]]] = https_check,
) -> dict[str, Any]:
    observed = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    evidence: list[dict[str, Any]] = []
    issues: list[dict[str, str]] = []
    for check in policy["checks"]:
        try:
            value, found = probe(check, now=observed)
            evidence.append(value)
            issues.extend(found)
        except (ExternalProbeError, common.MonitoringError, OSError, ssl.SSLError) as exc:
            evidence.append({"name": check["name"], "url": check["url"], "observation": "failed"})
            issues.append(
                common.issue(
                    f"external.{check['name']}-unreachable",
                    "critical",
                    f"{check['name']} HTTPS observation failed: {exc}",
                    "investigate DNS, routing, VPN, TLS, edge and origin from the independent probe host",
                )
            )
    unique = {item["code"]: item for item in issues}
    sorted_issues = [unique[key] for key in sorted(unique)]
    return {
        "format": "uten-imp-external-monitor-report-v1",
        "source": "external",
        "observedAtUtc": common.utc_text(observed),
        "bootId": _boot_id(),
        "policySha256": hashlib.sha256(policy_raw).hexdigest(),
        "status": "PASS" if not sorted_issues else "FAIL",
        "issues": sorted_issues,
        "evidence": {"checks": evidence},
        "containsSecrets": False,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check",))
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    parser.add_argument("--state", type=Path, default=DEFAULT_STATE)
    return parser


def _production_paths(args: argparse.Namespace) -> None:
    if common.test_mode():
        return
    if os.name != "posix" or os.geteuid() != 0:
        raise ExternalProbeError("production external monitor requires root on POSIX")
    if args.policy != DEFAULT_POLICY or args.state != DEFAULT_STATE:
        raise ExternalProbeError("production external monitor paths are fixed")


def main() -> int:
    args = build_parser().parse_args()
    try:
        _production_paths(args)
        common.assert_private_directory(args.state, create=True)
        policy_raw, policy = load_policy(args.policy)
        report = collect_report(policy_raw, policy)
        report_path = args.state / "external-latest.json"
        common.write_report(report_path, report)
        created, pending = alert_spool.record_report(
            report_path, "external", args.state
        )
        print(
            json.dumps(
                {
                    "status": report["status"],
                    "issues": len(report["issues"]),
                    "alertsCreated": created,
                    "alertsPending": pending,
                    "reportSha256": hashlib.sha256(common.canonical_json(report)).hexdigest(),
                },
                sort_keys=True,
            )
        )
        return 0
    except (ExternalProbeError, common.MonitoringError, alert_spool.AlertError, OSError, ValueError) as exc:
        print(f"EXTERNAL_MONITOR_ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
