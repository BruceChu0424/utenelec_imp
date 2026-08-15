#!/usr/bin/env python3
"""Render and strictly validate the reviewed Aliyun RAM/OSS policy bundle."""

from __future__ import annotations

import hashlib
import json
import re
import urllib.parse
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
BUNDLE_VERSION = "v1"
POLICY_FILES = (
    "publisher-trust.json",
    "publisher-permission.json",
    "bootstrap-trust.json",
    "bootstrap-permission.json",
    "server-downloader-trust.json",
    "server-downloader-permission.json",
    "server-assumer-permission.json",
)
EXACT_TOP_LEVEL = {
    "schemaVersion",
    "environmentClass",
    "accountId",
    "bucket",
    "ossEndpoint",
    "ossRegion",
    "keyPrefix",
    "github",
    "roles",
    "policies",
    "serverPrincipalArn",
    "requiredLiveControls",
}
EXACT_GITHUB = {
    "repository",
    "oidcProviderArn",
    "issuer",
    "audience",
    "publisherEnvironment",
    "bootstrapEnvironment",
}
EXACT_ROLES = {"publisher", "bootstrap", "serverDownloader"}
EXACT_POLICIES = {"publisher", "bootstrap", "serverDownloader", "serverAssumer"}
EXACT_CONTROLS = {
    "versioning",
    "wormMode",
    "wormLocked",
    "nonProductionWriteTestAllowed",
}
OFFICIAL_SOURCES = (
    "https://docs.github.com/en/actions/reference/security/oidc",
    "https://github.com/aliyun/configure-aliyun-credentials-action/tree/1e5248c8d5d93a8781ac344a68e19a43341e79e6",
    "https://www.alibabacloud.com/help/en/ram/user-guide/create-a-ram-role-for-a-trusted-idp",
    "https://www.alibabacloud.com/help/en/ram/user-guide/ram-role-overview",
    "https://www.alibabacloud.com/help/en/ram/user-guide/edit-the-trust-policy-of-a-ram-role",
    "https://www.alibabacloud.com/help/en/ram/policy-elements",
    "https://www.alibabacloud.com/help/en/oss/user-guide/authorization-syntax-and-elements",
    "https://www.alibabacloud.com/help/en/oss/developer-reference/putobject",
    "https://www.alibabacloud.com/help/en/oss/user-guide/overview-78/",
    "https://www.alibabacloud.com/help/en/oss/user-guide/oss-retention-policies",
    "https://www.alibabacloud.com/help/en/oss/user-guide/object-level-retention-policy-object-worm",
    "https://www.alibabacloud.com/help/en/oss/developer-reference/getbucketworm",
)


class PolicyError(ValueError):
    pass


def _require_exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        actual = sorted(value) if isinstance(value, dict) else type(value).__name__
        raise PolicyError(f"{label} keys differ: expected={sorted(expected)!r} actual={actual!r}")
    return value


def _require_text(value: Any, pattern: str, label: str, maximum: int = 255) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum or re.fullmatch(pattern, value) is None:
        raise PolicyError(f"{label} is invalid")
    return value


def load_config(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 64 * 1024:
        raise PolicyError("configuration must be a small regular non-symlink file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise PolicyError(f"cannot read configuration: {exc}") from exc
    return validate_config(value)


def validate_config(value: Any) -> dict[str, Any]:
    config = _require_exact_keys(value, EXACT_TOP_LEVEL, "configuration")
    if config["schemaVersion"] != SCHEMA_VERSION:
        raise PolicyError("unsupported schemaVersion")
    if config["environmentClass"] not in {"production", "nonproduction"}:
        raise PolicyError("environmentClass must be production or nonproduction")
    account = _require_text(config["accountId"], r"[0-9]{6,32}", "accountId", 32)
    _require_text(config["bucket"], r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]", "bucket", 63)
    endpoint = config["ossEndpoint"]
    if not isinstance(endpoint, str):
        raise PolicyError("ossEndpoint is invalid")
    parsed_endpoint = urllib.parse.urlsplit(endpoint)
    if (
        parsed_endpoint.scheme != "https"
        or not parsed_endpoint.hostname
        or parsed_endpoint.username is not None
        or parsed_endpoint.password is not None
        or parsed_endpoint.path not in ("", "/")
        or parsed_endpoint.query
        or parsed_endpoint.fragment
    ):
        raise PolicyError("ossEndpoint must be a plain HTTPS origin")
    _require_text(config["ossRegion"], r"[a-z0-9-]{2,64}", "ossRegion", 64)
    prefix = config["keyPrefix"]
    if not isinstance(prefix, str) or len(prefix) > 256:
        raise PolicyError("keyPrefix is invalid")
    if prefix and (
        not prefix.endswith("/")
        or prefix.startswith("/")
        or "//" in prefix
        or ".." in prefix.split("/")
        or re.fullmatch(r"[A-Za-z0-9._/-]+/", prefix) is None
    ):
        raise PolicyError("keyPrefix must be empty or a canonical relative prefix ending in /")
    if config["environmentClass"] == "production" and prefix:
        raise PolicyError("production workflow uses fixed root keys, so production keyPrefix must be empty")

    github = _require_exact_keys(config["github"], EXACT_GITHUB, "github")
    _require_text(github["repository"], r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", "github.repository")
    provider_pattern = rf"acs:ram::{re.escape(account)}:oidc-provider/[A-Za-z0-9._@/-]+"
    _require_text(github["oidcProviderArn"], provider_pattern, "github.oidcProviderArn", 512)
    if github["issuer"] != "https://token.actions.githubusercontent.com":
        raise PolicyError("GitHub issuer must be exact and must not contain a wildcard")
    if github["audience"] != "github-actions":
        raise PolicyError("GitHub audience must exactly match the reviewed workflow audience")
    for name in ("publisherEnvironment", "bootstrapEnvironment"):
        _require_text(github[name], r"[A-Za-z0-9_.-]+", f"github.{name}")
    if github["publisherEnvironment"] == github["bootstrapEnvironment"]:
        raise PolicyError("publisher and bootstrap must use independent GitHub environments")

    roles = _require_exact_keys(config["roles"], EXACT_ROLES, "roles")
    policies = _require_exact_keys(config["policies"], EXACT_POLICIES, "policies")
    for label, values in (("role", roles), ("policy", policies)):
        for name, item in values.items():
            _require_text(item, r"[A-Za-z0-9.@_-]+", f"{label}.{name}", 128)
        if len(set(values.values())) != len(values):
            raise PolicyError(f"all {label} names must be independent")

    # A RAM user would require a long-lived AccessKey to call STS from the server.
    # Bind the downloader assumption policy only to a role so commissioning must
    # provide a separately governed short-lived workload identity/broker.
    server_pattern = rf"acs:ram::{re.escape(account)}:role/[A-Za-z0-9.@_-]+"
    _require_text(config["serverPrincipalArn"], server_pattern, "serverPrincipalArn", 512)
    controls = _require_exact_keys(config["requiredLiveControls"], EXACT_CONTROLS, "requiredLiveControls")
    if controls["versioning"] != "Enabled":
        raise PolicyError("versioning must be required as Enabled")
    if controls["wormMode"] != "COMPLIANCE" or controls["wormLocked"] is not True:
        raise PolicyError("locked COMPLIANCE WORM must be required")
    if not isinstance(controls["nonProductionWriteTestAllowed"], bool):
        raise PolicyError("nonProductionWriteTestAllowed must be boolean")
    if config["environmentClass"] == "production" and controls["nonProductionWriteTestAllowed"]:
        raise PolicyError("production configuration must forbid write acceptance")
    if controls["nonProductionWriteTestAllowed"] and not prefix.startswith("acceptance/"):
        raise PolicyError("non-production write acceptance requires an acceptance/ keyPrefix")
    return config


def _json_scalar(value: str) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _variables(config: dict[str, Any]) -> dict[str, str]:
    github = config["github"]
    bucket = config["bucket"]
    prefix = config["keyPrefix"]
    object_base = f"acs:oss:*:*:{bucket}/{prefix}"
    repository = github["repository"]
    values = {
        "OIDC_PROVIDER_ARN_JSON": github["oidcProviderArn"],
        "OIDC_ISSUER_JSON": github["issuer"],
        "OIDC_AUDIENCE_JSON": github["audience"],
        "PUBLISHER_SUBJECT_JSON": f"repo:{repository}:environment:{github['publisherEnvironment']}",
        "BOOTSTRAP_SUBJECT_JSON": f"repo:{repository}:environment:{github['bootstrapEnvironment']}",
        "SERVER_PRINCIPAL_ARN_JSON": config["serverPrincipalArn"],
        "LATEST_RESOURCE_JSON": object_base + "channels/candidate/LATEST.txt",
        "VERSIONED_CHANNEL_RESOURCE_JSON": object_base + "channels/candidate/v*",
        "VERSIONED_CHANNEL_JSON_RESOURCE_JSON": object_base + "channels/candidate/v*.json",
        "VERSIONED_CHANNEL_SIG_RESOURCE_JSON": object_base + "channels/candidate/v*.sig",
        "RELEASE_RESOURCE_JSON": object_base + "releases/*",
        "ALL_RELEASE_OBJECTS_RESOURCE_JSON": object_base + "*",
        "SERVER_DOWNLOADER_ROLE_RESOURCE_JSON": (
            f"acs:ram:*:{config['accountId']}:role/{config['roles']['serverDownloader']}"
        ),
    }
    return {key: _json_scalar(value) for key, value in values.items()}


def _render_template(path: Path, variables: dict[str, str]) -> bytes:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 64 * 1024:
        raise PolicyError(f"unsafe template: {path}")
    text = path.read_text(encoding="utf-8")
    for name, value in variables.items():
        text = text.replace("{{" + name + "}}", value)
    leftovers = re.findall(r"\{\{[A-Z0-9_]+\}\}", text)
    if leftovers:
        raise PolicyError(f"unresolved template variables in {path.name}: {leftovers!r}")
    try:
        document = json.loads(text)
    except json.JSONDecodeError as exc:
        raise PolicyError(f"rendered template is not JSON: {path.name}: {exc}") from exc
    return (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def render_documents(config: dict[str, Any], base_dir: Path) -> dict[str, bytes]:
    templates = base_dir / BUNDLE_VERSION / "templates"
    variables = _variables(config)
    result: dict[str, bytes] = {}
    for output_name in POLICY_FILES:
        template = templates / (output_name + ".tmpl")
        result[output_name] = _render_template(template, variables)
    return result


def build_metadata(config: dict[str, Any], documents: dict[str, bytes]) -> dict[str, Any]:
    account = config["accountId"]
    roles = config["roles"]
    return {
        "schemaVersion": SCHEMA_VERSION,
        "bundleVersion": BUNDLE_VERSION,
        "config": config,
        "roleArns": {
            name: f"acs:ram::{account}:role/{role}"
            for name, role in roles.items()
        },
        "documentSha256": {
            name: hashlib.sha256(raw).hexdigest()
            for name, raw in sorted(documents.items())
        },
        "commissioning": {
            "status": "NO-GO",
            "ramCreateOnlyOrCasEnforced": False,
            "reason": (
                "RAM maps both first upload and same-key overwrite to oss:PutObject and exposes no "
                "documented create-only/CAS condition key. Client forbid-overwrite is not IAM enforcement."
            ),
            "requiredLiveEvidence": [
                "bucket versioning is Enabled",
                "COMPLIANCE WORM is locked for release evidence",
                "isolated non-production same-key overwrite behavior is recorded",
                "publisher/bootstrap OIDC positive and wrong-subject negative tests are recorded",
                "server downloader allowed-read and forbidden-write/delete tests are recorded",
                "current workflow uses the independent role and environment names in this bundle",
            ],
        },
        "officialSources": list(OFFICIAL_SOURCES),
    }


def canonical_metadata(metadata: dict[str, Any]) -> bytes:
    return (json.dumps(metadata, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def validate_bundle(bundle: Path, base_dir: Path) -> dict[str, Any]:
    if bundle.is_symlink() or not bundle.is_dir():
        raise PolicyError("bundle must be a real directory")
    actual = {item.name for item in bundle.iterdir()}
    expected = set(POLICY_FILES) | {"bundle-metadata.json"}
    if actual != expected:
        raise PolicyError(f"bundle inventory differs: expected={sorted(expected)!r} actual={sorted(actual)!r}")
    for item in bundle.iterdir():
        if item.is_symlink() or not item.is_file() or item.stat().st_size > 128 * 1024:
            raise PolicyError(f"unsafe bundle member: {item.name}")
    try:
        metadata = json.loads((bundle / "bundle-metadata.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise PolicyError(f"invalid metadata: {exc}") from exc
    expected_metadata_keys = {
        "schemaVersion", "bundleVersion", "config", "roleArns", "documentSha256",
        "commissioning", "officialSources",
    }
    _require_exact_keys(metadata, expected_metadata_keys, "bundle metadata")
    config = validate_config(metadata["config"])
    documents = render_documents(config, base_dir)
    rebuilt = build_metadata(config, documents)
    if metadata != rebuilt:
        raise PolicyError("bundle metadata differs from the strict v1 contract")
    for name, expected_raw in documents.items():
        actual_raw = (bundle / name).read_bytes()
        if actual_raw != expected_raw:
            raise PolicyError(f"rendered policy differs from the strict template: {name}")
        if hashlib.sha256(actual_raw).hexdigest() != metadata["documentSha256"][name]:
            raise PolicyError(f"policy digest differs: {name}")
    if metadata["commissioning"]["status"] != "NO-GO":
        raise PolicyError("RAM create-only/CAS limitation must remain fail-closed")
    return metadata


def workflow_gaps(metadata: dict[str, Any], workflow_path: Path) -> list[str]:
    if workflow_path.is_symlink() or not workflow_path.is_file():
        raise PolicyError("workflow path must be a regular non-symlink file")
    text = workflow_path.read_text(encoding="utf-8")
    github = metadata["config"]["github"]

    def job_block(name: str) -> str | None:
        marker = f"  {name}:"
        start = text.find(marker)
        if start < 0:
            return None
        following = re.search(r"(?m)^  [A-Za-z0-9_-]+:\s*$", text[start + len(marker):])
        end = len(text) if following is None else start + len(marker) + following.start()
        return text[start:end]

    gaps: list[str] = []
    contracts = (
        (
            "publish-release",
            github["publisherEnvironment"],
            "ALIYUN_RELEASE_PUBLISHER_ROLE_ARN",
        ),
        (
            "bootstrap-initial-candidate",
            github["bootstrapEnvironment"],
            "ALIYUN_RELEASE_BOOTSTRAP_ROLE_ARN",
        ),
    )
    for job_name, environment, role_variable in contracts:
        block = job_block(job_name)
        if block is None:
            gaps.append(f"missing job: {job_name}")
            continue
        for required in (
            f"environment: {environment}",
            f"${{{{ vars.{role_variable} }}}}",
            f"role-to-assume: ${{{{ vars.{role_variable} }}}}",
            f"audience: {github['audience']}",
        ):
            if required not in block:
                gaps.append(f"{job_name}: {required}")
        if "ALIYUN_RELEASE_ROLE_ARN" in block:
            gaps.append(f"{job_name}: legacy ALIYUN_RELEASE_ROLE_ARN")
    for required in (
        "RELEASE_REF_PROTECTED: ${{ github.ref_protected }}",
        "RELEASE_REF_TYPE: ${{ github.ref_type }}",
        "python3 deploy/release/release_tools.py validate-version",
    ):
        if required not in text:
            gaps.append(f"protected release ref gate: {required}")
    for forbidden in (
        "${{ secrets.OSS_",
        "${{ secrets.ALIBABA_CLOUD_",
        "${{ secrets.ALICLOUD_",
        "${{ secrets.ALIYUN_",
        "ALIYUN_ACCESS_KEY_ID",
        "ALIYUN_ACCESS_KEY_SECRET",
    ):
        if forbidden in text:
            gaps.append(f"forbidden long-term cloud credential interface: {forbidden}")
    return gaps
