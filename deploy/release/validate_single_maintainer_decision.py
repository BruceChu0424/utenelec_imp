#!/usr/bin/env python3
"""Fail-closed validator for the single-maintainer internal-test decision."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any


VERSION_RE = re.compile(r"v(20[0-9]{2})\.(0[1-9]|1[0-2])\.([0-2][0-9]|3[01])-([1-9][0-9]{0,2})")
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
KEY_ID_RE = re.compile(r"SHA256:[A-Za-z0-9+/]{43}")
UTC_RE = re.compile(r"20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")

TOP_KEYS = {
    "activationAuthorized",
    "authoritySeparation",
    "candidate",
    "changeReference",
    "commitSha",
    "decidedAtUtc",
    "decisionMode",
    "environment",
    "independentReviewerPresent",
    "maintainerCount",
    "manualActivationRequired",
    "ossPublicationAuthorized",
    "publication",
    "remoteTagPublished",
    "residualRisks",
    "schemaVersion",
    "singleMaintainerException",
    "sourceRef",
    "stagingAuthorized",
    "targetHostAuthority",
    "version",
}
AUTHORITY_KEYS = {
    "adminKeyAEvidenceRef",
    "adminKeyBEvidenceRef",
    "gitTagSigningKeyId",
    "releaseArtifactSigningKeyId",
    "serverHostKeyEvidenceRef",
}
CANDIDATE_KEYS = {
    "githubEvidenceSha256",
    "manifestTemplateSha256",
    "publishCandidateSha256",
    "verifiedCandidateReceiptSha256",
}
PUBLICATION_KEYS = {
    "channelSha256",
    "manifestSha256",
    "sourceTagBundleSha256",
    "sourceTagObjectSha",
    "updaterWheelhouseAttestationSha256",
}
TARGET_KEYS = {
    "evidenceReference",
    "h01ToH12Complete",
    "projectKnownHostsComplete",
}
REQUIRED_RISKS = [
    "github-private-repository-protection-unavailable",
    "manual-staging-and-activation-required",
    "no-independent-human-reviewer",
]


class DecisionError(ValueError):
    pass


def fail(message: str) -> None:
    raise DecisionError(message)


def _object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            fail(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def _reject_constant(value: str) -> None:
    fail(f"non-finite JSON number is forbidden: {value}")


def canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")


def load_canonical_json(path: Path) -> tuple[dict[str, Any], bytes]:
    metadata = os.lstat(path)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_size <= 0
        or metadata.st_size > 8 * 1024 * 1024
    ):
        fail("decision JSON must be one bounded regular single-link file")
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        fail("decision JSON must not contain a UTF-8 BOM")
    if b"\r" in raw or any(byte < 0x20 and byte not in (0x09, 0x0A) for byte in raw):
        fail("decision JSON contains a control character or non-canonical newline")
    try:
        text = raw.decode("utf-8")
        value = json.loads(
            text,
            object_pairs_hook=_object_pairs,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"decision JSON is invalid: {error}")
    if not isinstance(value, dict):
        fail("decision JSON must be an object")
    if canonical_json_bytes(value) != raw:
        fail("decision JSON is not canonical sort-keys two-space JSON")
    return value, raw


def exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    actual = set(value)
    if actual != expected:
        fail(f"{label} keys differ: missing={sorted(expected-actual)} extra={sorted(actual-expected)}")
    return value


def require_string(value: Any, label: str, pattern: re.Pattern[str] | None = None) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        fail(f"{label} must be one non-empty trimmed string")
    if pattern is not None and pattern.fullmatch(value) is None:
        fail(f"{label} is not canonical")
    return value


def require_bool(value: Any, label: str, expected: bool) -> None:
    if type(value) is not bool or value is not expected:
        fail(f"{label} must be {str(expected).lower()}")


def require_sha(value: Any, label: str) -> str:
    return require_string(value, label, SHA256_RE)


def require_optional_reference(value: Any, label: str) -> None:
    if value is not None:
        reference = require_string(value, label)
        if not reference.startswith("evidence:"):
            fail(f"{label} must use the evidence: namespace")


def require_timestamp(value: Any, label: str) -> str:
    text = require_string(value, label, UTC_RE)
    try:
        parsed = dt.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except ValueError as error:
        fail(f"{label} is not a real UTC timestamp: {error}")
    if parsed.year < 2026:
        fail(f"{label} predates this exception contract")
    return text


def validate_decision(
    value: dict[str, Any],
    *,
    expected_version: str | None = None,
    expected_commit: str | None = None,
    expected_manifest_sha256: str | None = None,
    expected_channel_sha256: str | None = None,
    expected_candidate_receipt_sha256: str | None = None,
    expected_github_evidence_sha256: str | None = None,
    expected_manifest_template_sha256: str | None = None,
    expected_publish_candidate_sha256: str | None = None,
    expected_source_tag_bundle_sha256: str | None = None,
    expected_source_tag_object_sha: str | None = None,
    expected_updater_attestation_sha256: str | None = None,
    expected_release_key_id: str | None = None,
    expected_tag_key_id: str | None = None,
) -> dict[str, str]:
    exact_keys(value, TOP_KEYS, "decision")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        fail("schemaVersion must be canonical integer 1")
    version = require_string(value["version"], "version", VERSION_RE)
    commit = require_string(value["commitSha"], "commitSha", COMMIT_RE)
    if value["sourceRef"] != f"refs/tags/{version}":
        fail("sourceRef must be refs/tags/<version>")
    require_timestamp(value["decidedAtUtc"], "decidedAtUtc")
    if value["environment"] != "internal-test":
        fail("environment must be internal-test")
    if value["decisionMode"] != "single-maintainer-offline-exception":
        fail("decisionMode is invalid")
    if type(value["maintainerCount"]) is not int or value["maintainerCount"] != 1:
        fail("maintainerCount must be canonical integer 1")
    require_bool(value["singleMaintainerException"], "singleMaintainerException", True)
    require_bool(value["independentReviewerPresent"], "independentReviewerPresent", False)
    require_bool(value["manualActivationRequired"], "manualActivationRequired", True)
    require_bool(value["activationAuthorized"], "activationAuthorized", False)
    require_bool(value["stagingAuthorized"], "stagingAuthorized", False)
    require_bool(value["ossPublicationAuthorized"], "ossPublicationAuthorized", False)
    require_bool(value["remoteTagPublished"], "remoteTagPublished", False)
    change_reference = require_string(value["changeReference"], "changeReference")
    if not change_reference.startswith("evidence:"):
        fail("changeReference must use the evidence: namespace")

    authority = exact_keys(value["authoritySeparation"], AUTHORITY_KEYS, "authoritySeparation")
    release_key = require_string(
        authority["releaseArtifactSigningKeyId"],
        "authoritySeparation.releaseArtifactSigningKeyId",
        KEY_ID_RE,
    )
    tag_key = require_string(
        authority["gitTagSigningKeyId"],
        "authoritySeparation.gitTagSigningKeyId",
        KEY_ID_RE,
    )
    if release_key == tag_key:
        fail("Git tag and Release artifact signing keys must be different")
    for key in ("adminKeyAEvidenceRef", "adminKeyBEvidenceRef", "serverHostKeyEvidenceRef"):
        require_optional_reference(authority[key], f"authoritySeparation.{key}")
    authority_references = [
        authority[key]
        for key in ("adminKeyAEvidenceRef", "adminKeyBEvidenceRef", "serverHostKeyEvidenceRef")
        if authority[key] is not None
    ]
    if len(authority_references) != len(set(authority_references)):
        fail("Admin A, Admin B, and Host Key evidence references must be distinct")

    candidate = exact_keys(value["candidate"], CANDIDATE_KEYS, "candidate")
    for key in sorted(CANDIDATE_KEYS):
        require_sha(candidate[key], f"candidate.{key}")
    publication = exact_keys(value["publication"], PUBLICATION_KEYS, "publication")
    for key in sorted(PUBLICATION_KEYS - {"sourceTagObjectSha"}):
        require_sha(publication[key], f"publication.{key}")
    require_string(publication["sourceTagObjectSha"], "publication.sourceTagObjectSha", COMMIT_RE)

    target = exact_keys(value["targetHostAuthority"], TARGET_KEYS, "targetHostAuthority")
    h_complete = target["h01ToH12Complete"]
    hosts_complete = target["projectKnownHostsComplete"]
    if type(h_complete) is not bool or type(hosts_complete) is not bool:
        fail("targetHostAuthority completion fields must be booleans")
    evidence = target["evidenceReference"]
    if h_complete and hosts_complete:
        target_reference = require_string(evidence, "targetHostAuthority.evidenceReference")
        if not target_reference.startswith("evidence:"):
            fail("targetHostAuthority.evidenceReference must use evidence: namespace")
        required_authorities = [
            authority["adminKeyAEvidenceRef"],
            authority["adminKeyBEvidenceRef"],
            authority["serverHostKeyEvidenceRef"],
        ]
        if any(reference is None for reference in required_authorities):
            fail("complete target authority requires Admin A, Admin B, and Host Key evidence")
        if len(set([target_reference, *required_authorities])) != 4:
            fail("target OOB and three authority evidence references must be distinct")
    elif evidence is not None:
        fail("incomplete target authority must not claim an evidenceReference")

    risks = value["residualRisks"]
    if not isinstance(risks, list) or risks != REQUIRED_RISKS:
        fail("residualRisks must be the exact canonical residual-risk list")

    comparisons = [
        (version, expected_version, "version"),
        (commit, expected_commit, "commitSha"),
        (publication["manifestSha256"], expected_manifest_sha256, "manifestSha256"),
        (publication["channelSha256"], expected_channel_sha256, "channelSha256"),
        (candidate["verifiedCandidateReceiptSha256"], expected_candidate_receipt_sha256, "verifiedCandidateReceiptSha256"),
        (candidate["githubEvidenceSha256"], expected_github_evidence_sha256, "githubEvidenceSha256"),
        (candidate["manifestTemplateSha256"], expected_manifest_template_sha256, "manifestTemplateSha256"),
        (candidate["publishCandidateSha256"], expected_publish_candidate_sha256, "publishCandidateSha256"),
        (publication["sourceTagBundleSha256"], expected_source_tag_bundle_sha256, "sourceTagBundleSha256"),
        (publication["sourceTagObjectSha"], expected_source_tag_object_sha, "sourceTagObjectSha"),
        (publication["updaterWheelhouseAttestationSha256"], expected_updater_attestation_sha256, "updaterWheelhouseAttestationSha256"),
        (release_key, expected_release_key_id, "releaseArtifactSigningKeyId"),
        (tag_key, expected_tag_key_id, "gitTagSigningKeyId"),
    ]
    for actual, expected, label in comparisons:
        if expected is not None and actual != expected:
            fail(f"{label} differs from the independently supplied expected value")
    return {
        "version": version,
        "commitSha": commit,
        "releaseKeyId": release_key,
        "tagKeyId": tag_key,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    validate = subcommands.add_parser("validate")
    validate.add_argument("--decision", required=True, type=Path)
    validate.add_argument("--expected-version")
    validate.add_argument("--expected-commit")
    validate.add_argument("--expected-manifest-sha256")
    validate.add_argument("--expected-channel-sha256")
    validate.add_argument("--expected-candidate-receipt-sha256")
    validate.add_argument("--expected-github-evidence-sha256")
    validate.add_argument("--expected-manifest-template-sha256")
    validate.add_argument("--expected-publish-candidate-sha256")
    validate.add_argument("--expected-source-tag-bundle-sha256")
    validate.add_argument("--expected-source-tag-object-sha")
    validate.add_argument("--expected-updater-attestation-sha256")
    validate.add_argument("--expected-release-key-id")
    validate.add_argument("--expected-tag-key-id")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        value, raw = load_canonical_json(args.decision.resolve())
        summary = validate_decision(
            value,
            expected_version=args.expected_version,
            expected_commit=args.expected_commit,
            expected_manifest_sha256=args.expected_manifest_sha256,
            expected_channel_sha256=args.expected_channel_sha256,
            expected_candidate_receipt_sha256=args.expected_candidate_receipt_sha256,
            expected_github_evidence_sha256=args.expected_github_evidence_sha256,
            expected_manifest_template_sha256=args.expected_manifest_template_sha256,
            expected_publish_candidate_sha256=args.expected_publish_candidate_sha256,
            expected_source_tag_bundle_sha256=args.expected_source_tag_bundle_sha256,
            expected_source_tag_object_sha=args.expected_source_tag_object_sha,
            expected_updater_attestation_sha256=args.expected_updater_attestation_sha256,
            expected_release_key_id=args.expected_release_key_id,
            expected_tag_key_id=args.expected_tag_key_id,
        )
        summary["decisionSha256"] = hashlib.sha256(raw).hexdigest()
        print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
        return 0
    except (DecisionError, OSError) as error:
        print(f"decision validation failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
