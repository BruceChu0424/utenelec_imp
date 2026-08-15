#!/usr/bin/env python3
"""Fail-closed, secret-free Aliyun policy acceptance helper.

The default is a plan. Read-only mode reads RAM/OSS configuration. Write mode is
possible only for a bundle rendered for an isolated non-production prefix.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path
from typing import Any

from policy_lib import POLICY_FILES, PolicyError, validate_bundle


SENSITIVE_KEYS = {
    "accesskeyid", "accesskeysecret", "securitytoken", "password", "credentials",
    "oidctoken", "secret",
}


def _run(command: list[str], *, allow_failure: bool = False) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(command, text=True, capture_output=True, check=False)
    if completed.returncode and not allow_failure:
        operation = command[1] if len(command) > 1 else "<no-operation>"
        raise PolicyError(
            f"cloud command failed without exposing command output: "
            f"{command[0]} {operation} (exit {completed.returncode})"
        )
    return completed


def _json_output(command: list[str]) -> Any:
    completed = _run(command)
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise PolicyError(f"expected JSON from {command[0]} {command[1]}") from exc
    _reject_sensitive(value)
    return value


def _reject_sensitive(value: Any) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if str(key).lower().replace("_", "") in SENSITIVE_KEYS:
                raise PolicyError("cloud readback unexpectedly contained a credential-like field")
            _reject_sensitive(child)
    elif isinstance(value, list):
        for child in value:
            _reject_sensitive(child)


def _find_key(value: Any, key: str) -> Any:
    if isinstance(value, dict):
        if key in value:
            return value[key]
        for child in value.values():
            found = _find_key(child, key)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = _find_key(child, key)
            if found is not None:
                return found
    return None


def _policy_document(value: Any, field: str) -> dict[str, Any]:
    raw = _find_key(value, field)
    if not isinstance(raw, str):
        raise PolicyError(f"cloud response did not contain {field}")
    try:
        decoded = urllib.parse.unquote(raw)
        document = json.loads(decoded)
    except json.JSONDecodeError as exc:
        raise PolicyError(f"cloud {field} is not a JSON policy") from exc
    if not isinstance(document, dict):
        raise PolicyError(f"cloud {field} is not a policy object")
    return document


def _canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _key_values(value: Any, key: str) -> list[Any]:
    found: list[Any] = []
    if isinstance(value, dict):
        for name, child in value.items():
            if name == key:
                found.append(child)
            found.extend(_key_values(child, key))
    elif isinstance(value, list):
        for child in value:
            found.extend(_key_values(child, key))
    return found


def _positive_retention(value: Any) -> bool:
    return (
        isinstance(value, int)
        and not isinstance(value, bool)
        and value > 0
    ) or (
        isinstance(value, str)
        and re.fullmatch(r"[1-9][0-9]*", value) is not None
    )


def _validate_worm_configuration(value: Any, source: str) -> None:
    """Require exact documented locked WORM state; never accept substrings."""
    if source == "object":
        enabled = _key_values(value, "ObjectWormEnabled")
        modes = _key_values(value, "Mode")
        retention = _key_values(value, "Days") + _key_values(value, "Years")
        valid = (
            enabled == ["Enabled"]
            and bool(modes)
            and all(item == "COMPLIANCE" for item in modes)
            and bool(retention)
            and all(_positive_retention(item) for item in retention)
        )
    elif source == "bucket":
        states = _key_values(value, "State")
        retention = _key_values(value, "RetentionPeriodInDays")
        valid = (
            states == ["Locked"]
            and bool(retention)
            and all(_positive_retention(item) for item in retention)
        )
    else:
        raise PolicyError("unknown WORM evidence source")
    if not valid:
        raise PolicyError("live WORM configuration is not exact locked COMPLIANCE protection")


def _write_evidence(path: Path, name: str, value: Any) -> None:
    target = path / name
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
        json.dump(value, output, ensure_ascii=False, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())


def _policy_version(policy_name: str) -> tuple[Any, Any]:
    policy = _json_output([
        "aliyun", "ram", "GetPolicy", "--PolicyType", "Custom", "--PolicyName", policy_name,
    ])
    version = _find_key(policy, "DefaultVersion") or _find_key(policy, "DefaultVersionId")
    if not isinstance(version, str) or re.fullmatch(r"v[1-9][0-9]*", version) is None:
        raise PolicyError(f"cannot find default version for custom policy {policy_name}")
    document = _json_output([
        "aliyun", "ram", "GetPolicyVersion", "--PolicyType", "Custom",
        "--PolicyName", policy_name, "--VersionId", version,
    ])
    return policy, document


def readonly_acceptance(metadata: dict[str, Any], evidence: Path) -> None:
    if evidence.exists():
        raise PolicyError("evidence directory must not already exist")
    evidence.mkdir(mode=0o700, parents=False)
    roles = metadata["config"]["roles"]
    policies = metadata["config"]["policies"]
    policy_files = {
        "publisher": "publisher-permission.json",
        "bootstrap": "bootstrap-permission.json",
        "serverDownloader": "server-downloader-permission.json",
    }
    trust_files = {
        "publisher": "publisher-trust.json",
        "bootstrap": "bootstrap-trust.json",
        "serverDownloader": "server-downloader-trust.json",
    }
    bundle = Path(metadata["_bundlePath"])
    for name in ("publisher", "bootstrap", "serverDownloader"):
        role = _json_output(["aliyun", "ram", "GetRole", "--RoleName", roles[name]])
        expected_trust = json.loads((bundle / trust_files[name]).read_text(encoding="utf-8"))
        if _canonical(_policy_document(role, "AssumeRolePolicyDocument")) != _canonical(expected_trust):
            raise PolicyError(f"live trust policy differs for {name}")
        attached = _json_output(["aliyun", "ram", "ListPoliciesForRole", "--RoleName", roles[name]])
        attached_names = set(re.findall(r'"PolicyName"\s*:\s*"([^"]+)"', json.dumps(attached)))
        attached_types = set(re.findall(r'"PolicyType"\s*:\s*"([^"]+)"', json.dumps(attached)))
        if attached_names != {policies[name]} or (attached_types and attached_types != {"Custom"}):
            raise PolicyError(f"role {name} must have exactly its one reviewed custom policy")
        policy, version = _policy_version(policies[name])
        expected_permission = json.loads((bundle / policy_files[name]).read_text(encoding="utf-8"))
        if _canonical(_policy_document(version, "PolicyDocument")) != _canonical(expected_permission):
            raise PolicyError(f"live permission policy differs for {name}")
        _write_evidence(evidence, f"{name}-role.json", role)
        _write_evidence(evidence, f"{name}-attachments.json", attached)
        _write_evidence(evidence, f"{name}-policy.json", policy)
        _write_evidence(evidence, f"{name}-policy-version.json", version)

    config = metadata["config"]
    common = [
        "--endpoint", config["ossEndpoint"], "--region", config["ossRegion"],
        "--addressing-style", "virtual", "--bucket", config["bucket"], "--output-format", "json",
    ]
    versioning = _json_output(["ossutil", "api", "get-bucket-versioning", *common])
    if _find_key(versioning, "Status") != "Enabled":
        raise PolicyError("live bucket versioning is not Enabled")
    _write_evidence(evidence, "oss-versioning.json", versioning)

    object_worm = _run(["ossutil", "api", "get-bucket-object-worm-configuration", *common], allow_failure=True)
    worm_value: Any = None
    worm_source: str | None = None
    if object_worm.returncode == 0:
        try:
            worm_value = json.loads(object_worm.stdout)
            worm_source = "object"
        except json.JSONDecodeError:
            worm_value = None
    if worm_value is None:
        bucket_worm = _run(["ossutil", "api", "get-bucket-worm", *common], allow_failure=True)
        if bucket_worm.returncode == 0:
            try:
                worm_value = json.loads(bucket_worm.stdout)
                worm_source = "bucket"
            except json.JSONDecodeError:
                worm_value = None
    if worm_value is None or worm_source is None:
        raise PolicyError("cannot prove a live locked WORM configuration")
    _reject_sensitive(worm_value)
    _validate_worm_configuration(worm_value, worm_source)
    _write_evidence(evidence, "oss-worm.json", worm_value)
    _write_evidence(evidence, "result.json", {
        "result": "READ_ONLY_EVIDENCE_PASS",
        "commissioning": "NO-GO",
        "reason": metadata["commissioning"]["reason"],
        "wormEvidenceType": worm_source,
        "recordedAtUtc": dt.datetime.now(dt.timezone.utc).isoformat(),
    })


def write_acceptance(metadata: dict[str, Any], evidence: Path, confirmation: str) -> None:
    config = metadata["config"]
    controls = config["requiredLiveControls"]
    expected = f"WRITE_TEST:{config['bucket']}:{config['keyPrefix']}"
    if (
        config["environmentClass"] != "nonproduction"
        or not controls["nonProductionWriteTestAllowed"]
        or not config["keyPrefix"].startswith("acceptance/")
        or confirmation != expected
    ):
        raise PolicyError("write acceptance requires a nonproduction acceptance/ bundle and exact confirmation")
    if evidence.exists():
        raise PolicyError("evidence directory must not already exist")
    evidence.mkdir(mode=0o700, parents=False)
    nonce = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    immutable_key = f"{config['keyPrefix']}releases/v2099.01.01-1/{nonce}.txt"
    common = [
        "--endpoint", config["ossEndpoint"], "--region", config["ossRegion"],
        "--addressing-style", "virtual", "--bucket", config["bucket"], "--key", immutable_key,
    ]
    with tempfile.TemporaryDirectory(prefix="uten-aliyun-accept-") as temporary:
        body = Path(temporary) / "probe.txt"
        body.write_text(f"uten-imp nonproduction acceptance {nonce}\n", encoding="ascii")
        first = _run(["ossutil", "api", "put-object", *common, "--body", f"file://{body}", "--forbid-overwrite", "true"])
        second = _run(["ossutil", "api", "put-object", *common, "--body", f"file://{body}"], allow_failure=True)
        outside_key = f"uten-imp-denied-probe/{nonce}.txt"
        outside = _run([
            "ossutil", "api", "put-object",
            "--endpoint", config["ossEndpoint"], "--region", config["ossRegion"],
            "--addressing-style", "virtual", "--bucket", config["bucket"],
            "--key", outside_key, "--body", f"file://{body}", "--forbid-overwrite", "true",
        ], allow_failure=True)
        deletion = _run([
            "ossutil", "api", "delete-object",
            "--endpoint", config["ossEndpoint"], "--region", config["ossRegion"],
            "--addressing-style", "virtual", "--bucket", config["bucket"], "--key", immutable_key,
        ], allow_failure=True)
        listing = _run([
            "ossutil", "api", "list-objects",
            "--endpoint", config["ossEndpoint"], "--region", config["ossRegion"],
            "--addressing-style", "virtual", "--bucket", config["bucket"],
            "--prefix", config["keyPrefix"], "--max-keys", "1",
        ], allow_failure=True)
    unsafe = second.returncode == 0 or outside.returncode == 0 or deletion.returncode == 0 or listing.returncode == 0
    _write_evidence(evidence, "write-result.json", {
        "result": "NO-GO" if unsafe else "WRITE_BOUNDARY_PASS_WITH_RAM_CREATE_ONLY_LIMITATION",
        "objectKey": immutable_key,
        "outsideObjectKey": outside_key,
        "initialPutExitCode": first.returncode,
        "unconditionalOverwriteExitCode": second.returncode,
        "outsidePrefixPutExitCode": outside.returncode,
        "deleteExitCode": deletion.returncode,
        "listExitCode": listing.returncode,
        "note": "The probe object is intentionally retained; the test identity has no delete permission.",
        "recordedAtUtc": dt.datetime.now(dt.timezone.utc).isoformat(),
    })
    if unsafe:
        raise PolicyError("one or more forbidden write/list operations succeeded; inspect retained evidence")


def role_read_probe(metadata: dict[str, Any], evidence: Path, role_name: str) -> None:
    if evidence.exists():
        raise PolicyError("evidence directory must not already exist")
    evidence.mkdir(mode=0o700, parents=False)
    config = metadata["config"]
    prefix = config["keyPrefix"]
    latest = f"{prefix}channels/candidate/LATEST.txt"
    common = [
        "--endpoint", config["ossEndpoint"], "--region", config["ossRegion"],
        "--addressing-style", "virtual", "--bucket", config["bucket"],
    ]
    with tempfile.TemporaryDirectory(prefix="uten-aliyun-read-") as temporary:
        destination = Path(temporary) / "LATEST.txt"
        allowed = _run([
            "ossutil", "api", "get-object", *common, "--key", latest,
            "--output-format", "raw", "--quiet",
        ], allow_failure=True)
        if allowed.returncode == 0:
            destination.write_text(allowed.stdout, encoding="utf-8")
        listing = _run([
            "ossutil", "api", "list-objects", *common, "--prefix", prefix, "--max-keys", "1",
        ], allow_failure=True)
        bucket_info = _run([
            "ossutil", "api", "get-bucket-info", *common, "--output-format", "json",
        ], allow_failure=True)
    result = {
        "role": role_name,
        "allowedLatestGetExitCode": allowed.returncode,
        "forbiddenListExitCode": listing.returncode,
        "forbiddenBucketInfoExitCode": bucket_info.returncode,
        "recordedAtUtc": dt.datetime.now(dt.timezone.utc).isoformat(),
    }
    _write_evidence(evidence, "role-read-probe.json", result)
    if allowed.returncode != 0 or listing.returncode == 0 or bucket_info.returncode == 0:
        raise PolicyError("role read positive/negative probe failed; inspect retained evidence")


def print_plan(metadata: dict[str, Any]) -> None:
    config = metadata["config"]
    print("PLAN ONLY; no cloud command was executed.")
    print("1. Read back three RAM role trust policies and exact attached custom policies.")
    print("2. Read OSS versioning and locked COMPLIANCE WORM configuration.")
    print("3. Retain sanitized JSON evidence; credential fields are rejected.")
    print("4. Keep commissioning NO-GO because RAM cannot enforce create-only/CAS for PutObject.")
    if config["environmentClass"] == "nonproduction" and config["requiredLiveControls"]["nonProductionWriteTestAllowed"]:
        print(f"Optional write confirmation: WRITE_TEST:{config['bucket']}:{config['keyPrefix']}")
    else:
        print("Write acceptance is disabled by this bundle.")


def main() -> int:
    parser = argparse.ArgumentParser(description="Aliyun RAM/OSS acceptance (plan by default)")
    parser.add_argument("--bundle", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--read-only", action="store_true")
    mode.add_argument("--write-test", action="store_true")
    mode.add_argument("--role-read-probe", choices=("publisher", "bootstrap", "server-downloader"))
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--confirm", default="")
    args = parser.parse_args()
    try:
        base = Path(__file__).resolve().parent
        metadata = validate_bundle(args.bundle, base)
        metadata["_bundlePath"] = str(args.bundle.resolve())
        if args.read_only or args.write_test or args.role_read_probe:
            if args.evidence is None:
                raise PolicyError("execution requires --evidence pointing to a new directory")
            for executable in ("aliyun", "ossutil") if args.read_only else ("ossutil",):
                if shutil.which(executable) is None:
                    raise PolicyError(f"required executable is unavailable: {executable}")
        if args.read_only:
            readonly_acceptance(metadata, args.evidence)
        elif args.write_test:
            write_acceptance(metadata, args.evidence, args.confirm)
        elif args.role_read_probe:
            role_read_probe(metadata, args.evidence, args.role_read_probe)
        else:
            print_plan(metadata)
        return 0
    except (OSError, PolicyError) as exc:
        print(f"ACCEPTANCE FAILED: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
