#!/usr/bin/env python3
"""Single-maintainer unsigned-candidate and offline-publication tooling.

The candidate verifier is stdlib-only and never imports or executes candidate
content.  GitHub/OSS/server credentials are intentionally absent from offline
commands.  Networked commands are explicit and fail closed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from typing import Any, Iterable


PRODUCT = "uten-imp"
DEFAULT_REPOSITORY = "UTEN-ELECTRICAL/uten_imp"
PLACEHOLDER_KEY_ID = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
RELEASE_NAMESPACE = "uten-imp-release-v1"
WHEELHOUSE_NAMESPACE = "uten-imp-updater-wheelhouse-v1"
DECISION_NAMESPACE = "uten-imp-single-maintainer-decision-v1"
SIGNER_IDENTITY = "uten-imp-release"
VERSION_RE = re.compile(r"v(20[0-9]{2})\.(0[1-9]|1[0-2])\.([0-2][0-9]|3[01])-([1-9][0-9]{0,2})")
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
KEY_ID_RE = re.compile(r"SHA256:[A-Za-z0-9+/]{43}")
ARTIFACT_RE = re.compile(r"uten-imp-(v20[0-9]{2}\.[0-9]{2}\.[0-9]{2}-[1-9][0-9]{0,2})-([0-9a-f]{12})\.tar\.gz")
MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_ZIP_BYTES = 256 * 1024 * 1024
MAX_TAR_MEMBER_BYTES = 256 * 1024 * 1024
MAX_TAR_TOTAL_BYTES = 512 * 1024 * 1024
MAX_OSS_DIAGNOSTIC_BYTES = 64 * 1024
MAX_OSS_TRANSITION_BYTES = 8 * 1024
CONFIRM_BUILD = "BUILD_UNSIGNED_INTERNAL_TEST_CANDIDATE_NO_SIGN_NO_PUBLISH"
CONFIRM_OSS = "PUBLISH_VERIFIED_SIGNED_INTERNAL_TEST_OBJECTS_CREATE_ONLY"
CONFIRM_BOOTSTRAP = "CREATE_INITIAL_SIGNED_INTERNAL_TEST_POINTER_ONCE"

WORKFLOW_JOBS = {
    ".github/workflows/quality.yml": {
        "Secret history scan",
        "Backend / Java 21",
        "Flutter / Web",
        "Deployment contracts",
    },
    ".github/workflows/codeql.yml": {"Java security and quality"},
    ".github/workflows/osv-scanner.yml": {
        "Generate dependency inputs",
        "scan / osv-scan",
    },
}
FIXED_CANDIDATE_MEMBERS = {
    "PUBLISH_SHA256SUMS",
    "backend.cdx.json",
    "flutter.cdx.json",
    "manifest.template.json",
    "updater-wheelhouse.attestation.json",
}
SIGNED_PUBLICATION_FIXED_MEMBERS = {
    "SIGNED_SHA256SUMS",
    "backend.cdx.json",
    "channel.json",
    "channel.sig",
    "flutter.cdx.json",
    "manifest.json",
    "manifest.sig",
    "release-decision.json",
    "release-decision.sig",
    "updater-wheelhouse.attestation.json",
    "updater-wheelhouse.attestation.sig",
}
PUBLICATION_INPUT_KEYS = {
    "candidateReceiptSha256",
    "channelSha256",
    "commitSha",
    "gitTagSigningKeyId",
    "githubEvidenceSha256",
    "manifestSha256",
    "manifestTemplateSha256",
    "product",
    "publishCandidateSha256",
    "releaseArtifactSigningKeyId",
    "schemaVersion",
    "sourceTagBundleSha256",
    "sourceTagObjectSha",
    "sourceTagReceiptSha256",
    "updaterWheelhouseAttestationSha256",
    "version",
}


class ReleaseError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise ReleaseError(message)


def _pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_constant(value: str) -> None:
    fail(f"non-finite JSON number is forbidden: {value}")


def canonical_json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def load_json_bytes(raw: bytes, label: str, *, canonical: bool = True) -> Any:
    if len(raw) > MAX_JSON_BYTES or raw.startswith(b"\xef\xbb\xbf") or b"\r" in raw:
        fail(f"{label} is oversized, BOM-prefixed, or uses non-canonical newlines")
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_pairs,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{label} is invalid JSON: {error}")
    if canonical and canonical_json_bytes(value) != raw:
        fail(f"{label} is not canonical JSON")
    return value


def load_json(path: Path, label: str, *, canonical: bool = True) -> tuple[Any, bytes]:
    path = regular_file(path, label, max_size=MAX_JSON_BYTES)
    raw = path.read_bytes()
    return load_json_bytes(raw, label, canonical=canonical), raw


def regular_file(
    path: Path,
    label: str,
    *,
    max_size: int | None = None,
    allow_empty: bool = False,
) -> Path:
    candidate = path.absolute()
    try:
        metadata = os.lstat(candidate)
    except OSError as error:
        fail(f"{label} cannot be inspected: {error}")
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        fail(f"{label} must be a regular non-symlink file")
    if metadata.st_nlink != 1:
        fail(f"{label} must have exactly one hard link")
    if (not allow_empty and metadata.st_size <= 0) or (
        max_size is not None and metadata.st_size > max_size
    ):
        fail(f"{label} size is invalid")
    return candidate


def regular_directory(path: Path, label: str) -> Path:
    candidate = path.absolute()
    try:
        metadata = os.lstat(candidate)
    except OSError as error:
        fail(f"{label} cannot be inspected: {error}")
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        fail(f"{label} must be a real non-symlink directory")
    return candidate


def write_json_exclusive(path: Path, value: Any, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(descriptor, "wb") as output:
        output.write(canonical_json_bytes(value))
        output.flush()
        os.fsync(output.fileno())


def write_bytes_exclusive(path: Path, raw: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(descriptor, "wb") as output:
        output.write(raw)
        output.flush()
        os.fsync(output.fileno())


def sha256_bytes(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_string(value: Any, label: str, pattern: re.Pattern[str] | None = None) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        fail(f"{label} must be one non-empty trimmed string")
    if pattern is not None and pattern.fullmatch(value) is None:
        fail(f"{label} is not canonical")
    return value


def require_int(value: Any, label: str, *, positive: bool = True) -> int:
    if type(value) is not int or (positive and value <= 0) or (not positive and value < 0):
        fail(f"{label} must be a canonical positive integer")
    return value


def require_exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    actual = set(value)
    if actual != expected:
        fail(f"{label} key set differs: missing={sorted(expected-actual)} extra={sorted(actual-expected)}")
    return value


def validate_version(value: str) -> int:
    match = VERSION_RE.fullmatch(value)
    if match is None:
        fail("version must be canonical vYYYY.MM.DD-N")
    year, month, day, counter = (int(item) for item in match.groups())
    try:
        date = dt.date(year, month, day)
    except ValueError as error:
        fail(f"version contains an invalid date: {error}")
    return int(f"{date:%Y%m%d}{counter:03d}")


def require_bucket(value: Any) -> str:
    bucket = require_string(value, "OSS bucket")
    if re.fullmatch(r"[a-z0-9][a-z0-9-]{1,62}", bucket) is None:
        fail("OSS bucket is not canonical")
    return bucket


def require_oss_region(value: Any) -> str:
    region = require_string(value, "OSS region")
    if re.fullmatch(r"[a-z0-9][a-z0-9-]{1,62}", region) is None:
        fail("OSS region is not canonical")
    return region


def require_oss_endpoint(value: Any) -> str:
    endpoint = require_string(value, "OSS endpoint")
    parsed = urllib.parse.urlparse(endpoint)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in ("", "/")
    ):
        fail("OSS endpoint must be a credential-free HTTPS origin")
    return endpoint


def publication_object_key(version: str, local_name: str) -> str:
    if local_name == "channel.json":
        return f"channels/candidate/{version}.json"
    if local_name == "channel.sig":
        return f"channels/candidate/{version}.sig"
    if local_name == "backend.cdx.json":
        return f"releases/{version}/sbom/backend.cdx.json"
    if local_name == "flutter.cdx.json":
        return f"releases/{version}/sbom/flutter.cdx.json"
    if local_name == "updater-wheelhouse.attestation.json":
        return f"releases/{version}/sbom/updater/updater-wheelhouse.attestation.json"
    if local_name == "updater-wheelhouse.attestation.sig":
        return f"releases/{version}/sbom/updater/updater-wheelhouse.attestation.sig"
    if local_name in {"release-decision.json", "release-decision.sig", "SIGNED_SHA256SUMS"}:
        return f"releases/{version}/evidence/{local_name}"
    if local_name in {"manifest.json", "manifest.sig"} or ARTIFACT_RE.fullmatch(
        local_name
    ) or (
        local_name.endswith(".sha256")
        and ARTIFACT_RE.fullmatch(local_name[: -len(".sha256")])
    ):
        return f"releases/{version}/{local_name}"
    fail(f"signed publication member has no canonical OSS mapping: {local_name}")


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


class _SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        parsed = urllib.parse.urlparse(new_url)
        if parsed.scheme != "https" or not parsed.netloc:
            fail("GitHub download redirect is not HTTPS")
        redirected = super().redirect_request(
            request, fp, code, message, headers, new_url
        )
        if redirected is None:
            return None
        original = urllib.parse.urlparse(request.full_url)
        if original.netloc != parsed.netloc:
            redirected.remove_header("Authorization")
        return redirected


class GitHubClient:
    def __init__(self, api_url: str, repository: str, token: str) -> None:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            fail("repository must be owner/name")
        parsed = urllib.parse.urlparse(api_url)
        if parsed.scheme != "https" or not parsed.netloc or parsed.path not in ("", "/"):
            fail("GitHub API URL must be an HTTPS origin")
        if not token:
            fail("GitHub token environment variable is empty")
        self.api_url = api_url.rstrip("/")
        self.repository = repository
        self.token = token
        self.opener = urllib.request.build_opener(_SafeRedirect())

    def request(
        self,
        path_or_url: str,
        *,
        accept: str = "application/vnd.github+json",
        allow_404: bool = False,
        allow_external_redirect: bool = False,
    ) -> tuple[bytes, Any, int]:
        url = path_or_url if path_or_url.startswith("https://") else self.api_url + path_or_url
        parsed = urllib.parse.urlparse(url)
        if f"{parsed.scheme}://{parsed.netloc}" != self.api_url:
            fail("GitHub pagination escaped the configured API origin")
        request = urllib.request.Request(
            url,
            headers={
                "Accept": accept,
                "Authorization": f"Bearer {self.token}",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "uten-imp-offline-release-v1",
            },
        )
        try:
            with self.opener.open(request, timeout=60) as response:
                final = urllib.parse.urlparse(response.geturl())
                final_origin = f"{final.scheme}://{final.netloc}"
                if final.scheme != "https" or (
                    final_origin != self.api_url and not allow_external_redirect
                ):
                    fail("GitHub API response redirected outside the approved origin")
                limit = MAX_ZIP_BYTES if accept == "application/octet-stream" else MAX_JSON_BYTES
                raw = response.read(limit + 1)
                if len(raw) > limit:
                    fail("GitHub response exceeds the bounded read limit")
                return raw, response.headers, response.status
        except urllib.error.HTTPError as error:
            if allow_404 and error.code == 404:
                return b"", error.headers, error.code
            fail(f"GitHub API request failed: HTTP {error.code} {parsed.path}")

    def json(self, path_or_url: str, *, allow_404: bool = False) -> tuple[Any, Any, int]:
        raw, headers, status = self.request(path_or_url, allow_404=allow_404)
        if status == 404:
            return None, headers, status
        return load_json_bytes(raw, "GitHub API response", canonical=False), headers, status

    def pages(self, path: str, key: str) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        next_url: str | None = path
        seen: set[str] = set()
        declared_total: int | None = None
        while next_url is not None:
            if next_url in seen or len(seen) >= 100:
                fail("GitHub pagination loop or page limit exceeded")
            seen.add(next_url)
            value, headers, _ = self.json(next_url)
            if not isinstance(value, dict) or not isinstance(value.get(key), list):
                fail(f"GitHub paginated response lacks {key}")
            if "total_count" in value:
                total = require_int(value["total_count"], "GitHub total_count", positive=False)
                if declared_total is None:
                    declared_total = total
                elif declared_total != total:
                    fail("GitHub pagination total_count changed")
            for item in value[key]:
                if not isinstance(item, dict):
                    fail("GitHub pagination returned a non-object item")
                result.append(item)
            next_url = _next_link(headers.get("Link"))
        if declared_total is not None and declared_total != len(result):
            fail("GitHub pagination is incomplete")
        return result


def _next_link(header: str | None) -> str | None:
    if not header:
        return None
    next_values: list[str] = []
    for part in header.split(","):
        match = re.fullmatch(r'\s*<([^>]+)>;\s*rel="([^"]+)"\s*', part)
        if match is None:
            fail("GitHub Link header is malformed")
        if match.group(2) == "next":
            next_values.append(match.group(1))
    if len(next_values) > 1:
        fail("GitHub Link header contains duplicate next relations")
    return next_values[0] if next_values else None


def verify_main_and_tag(client: GitHubClient, commit: str, version: str) -> None:
    value, _, _ = client.json(f"/repos/{client.repository}/git/ref/heads/main")
    if not isinstance(value, dict) or value.get("object", {}).get("sha") != commit:
        fail("current main differs from expected_main_sha")
    encoded = urllib.parse.quote(version, safe="")
    _tag, _, status = client.json(
        f"/repos/{client.repository}/git/ref/tags/{encoded}", allow_404=True
    )
    if status != 404:
        fail("remote release tag already exists")


def collect_main_ci(client: GitHubClient, commit: str) -> list[dict[str, Any]]:
    require_string(commit, "expected_main_sha", COMMIT_RE)
    evidence: list[dict[str, Any]] = []
    for workflow_path, expected_jobs in WORKFLOW_JOBS.items():
        workflow_id = urllib.parse.quote(Path(workflow_path).name, safe="")
        query = urllib.parse.urlencode(
            {"branch": "main", "event": "push", "head_sha": commit, "status": "completed", "per_page": 100}
        )
        runs = client.pages(
            f"/repos/{client.repository}/actions/workflows/{workflow_id}/runs?{query}",
            "workflow_runs",
        )
        matches = [
            run
            for run in runs
            if run.get("path") == workflow_path
            and run.get("event") == "push"
            and run.get("head_branch") == "main"
            and run.get("head_sha") == commit
        ]
        if len(matches) != 1:
            fail(f"expected exactly one current main run for {workflow_path}")
        run = matches[0]
        if run.get("status") != "completed" or run.get("conclusion") != "success":
            fail(f"workflow did not complete successfully: {workflow_path}")
        run_id = require_int(run.get("id"), f"{workflow_path}.run.id")
        attempt = require_int(run.get("run_attempt"), f"{workflow_path}.run_attempt")
        if attempt != 1:
            fail(f"main CI workflow run_attempt is not 1: {workflow_path}")
        jobs = client.pages(
            f"/repos/{client.repository}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100",
            "jobs",
        )
        names = [require_string(job.get("name"), "job.name") for job in jobs]
        if len(names) != len(set(names)) or set(names) != expected_jobs:
            fail(f"workflow job set differs for {workflow_path}: {sorted(names)}")
        job_evidence: list[dict[str, Any]] = []
        for job in jobs:
            if job.get("status") != "completed" or job.get("conclusion") != "success":
                fail(f"workflow job is not completed/success: {job.get('name')}")
            job_attempt = require_int(
                job.get("run_attempt"),
                f"{workflow_path}.{job.get('name')}.run_attempt",
            )
            if job.get("head_sha") != commit or job_attempt != 1:
                fail(f"workflow job lineage differs: {job.get('name')}")
            check_url = require_string(job.get("check_run_url"), "job.check_run_url")
            check, _, _ = client.json(check_url)
            if not isinstance(check, dict) or check.get("app", {}).get("slug") != "github-actions":
                fail(f"workflow job check app is not github-actions: {job.get('name')}")
            if check.get("name") != job.get("name") or check.get("head_sha") != commit or check.get("status") != "completed" or check.get("conclusion") != "success":
                fail(f"workflow job check lineage/status differs: {job.get('name')}")
            job_evidence.append(
                {
                    "appSlug": "github-actions",
                    "checkRunId": require_int(check.get("id"), "check_run.id"),
                    "conclusion": "success",
                    "headSha": commit,
                    "id": require_int(job.get("id"), "job.id"),
                    "name": job["name"],
                    "status": "completed",
                }
            )
        evidence.append(
            {
                "checkSuiteId": require_int(run.get("check_suite_id"), "run.check_suite_id"),
                "conclusion": "success",
                "event": "push",
                "headBranch": "main",
                "headSha": commit,
                "jobs": sorted(job_evidence, key=lambda item: item["name"]),
                "runAttempt": attempt,
                "runId": run_id,
                "status": "completed",
                "workflowPath": workflow_path,
            }
        )
    if {job["name"] for run in evidence for job in run["jobs"]} != set().union(*WORKFLOW_JOBS.values()):
        fail("combined CI job set is not the exact seven-job contract")
    return sorted(evidence, key=lambda item: item["workflowPath"])


def _regular_zip_member(info: zipfile.ZipInfo) -> bool:
    mode = (info.external_attr >> 16) & 0o170000
    return mode in (0, 0o100000) and not info.is_dir() and not (info.flag_bits & 0x1)


def candidate_tar_from_zip(raw: bytes) -> tuple[bytes, str]:
    if len(raw) <= 0 or len(raw) > MAX_ZIP_BYTES:
        fail("GitHub artifact ZIP size is invalid")
    try:
        with zipfile.ZipFile(io.BytesIO(raw), "r") as archive:
            infos = archive.infolist()
            if len(infos) != 1 or infos[0].filename != "publish-candidate.tar":
                fail("GitHub artifact ZIP must contain only publish-candidate.tar")
            info = infos[0]
            if not _regular_zip_member(info) or info.file_size <= 0 or info.file_size > MAX_ZIP_BYTES:
                fail("GitHub artifact ZIP member is unsafe or oversized")
            if info.compress_size <= 0 or info.file_size > info.compress_size * 4 + 1024 * 1024:
                fail("GitHub artifact ZIP compression ratio is unsafe")
            candidate = archive.read(info)
    except (zipfile.BadZipFile, RuntimeError) as error:
        fail(f"GitHub artifact ZIP is invalid: {error}")
    return candidate, sha256_bytes(candidate)


def parse_sha256_inventory(raw: bytes, expected_names: set[str]) -> dict[str, str]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        fail(f"SHA-256 inventory is not UTF-8: {error}")
    if "\r" in text or not text.endswith("\n"):
        fail("SHA-256 inventory is not canonical LF text")
    result: dict[str, str] = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)", line)
        if match is None or match.group(2) in result:
            fail("SHA-256 inventory contains a malformed or duplicate line")
        result[match.group(2)] = match.group(1)
    if set(result) != expected_names:
        fail("SHA-256 inventory member set differs")
    return result


def verify_candidate_tar(raw: bytes) -> dict[str, Any]:
    files: dict[str, bytes] = {}
    total = 0
    try:
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
            members = archive.getmembers()
            names = [member.name for member in members]
            if len(names) != len(set(names)) or len(names) != 7:
                fail("publish-candidate.tar must contain seven unique members")
            for member in members:
                if not member.isfile() or "/" in member.name or "\\" in member.name:
                    fail("publish-candidate.tar contains a non-regular or nested member")
                if member.size <= 0 or member.size > MAX_TAR_MEMBER_BYTES:
                    fail("publish-candidate.tar member size is invalid")
                total += member.size
                if total > MAX_TAR_TOTAL_BYTES:
                    fail("publish-candidate.tar expanded size exceeds the limit")
                stream = archive.extractfile(member)
                if stream is None:
                    fail("publish-candidate.tar member cannot be read")
                files[member.name] = stream.read()
    except (tarfile.TarError, EOFError) as error:
        fail(f"publish-candidate.tar is invalid: {error}")

    artifact_names = sorted(name for name in files if ARTIFACT_RE.fullmatch(name))
    if len(artifact_names) != 1:
        fail("candidate must contain exactly one canonical release artifact")
    artifact_name = artifact_names[0]
    expected = FIXED_CANDIDATE_MEMBERS | {artifact_name, f"{artifact_name}.sha256"}
    if set(files) != expected:
        fail("publish-candidate.tar exact member set differs")
    inventory_names = expected - {"PUBLISH_SHA256SUMS"}
    inventory = parse_sha256_inventory(files["PUBLISH_SHA256SUMS"], inventory_names)
    for name in inventory_names:
        if sha256_bytes(files[name]) != inventory[name]:
            fail(f"candidate member digest differs: {name}")
    checksum = files[f"{artifact_name}.sha256"].decode("utf-8", "strict")
    checksum_match = re.fullmatch(rf"([0-9a-f]{{64}})  {re.escape(artifact_name)}\n", checksum)
    artifact_sha = sha256_bytes(files[artifact_name])
    if checksum_match is None or checksum_match.group(1) != artifact_sha:
        fail("inner release artifact checksum line differs")
    manifest = load_json_bytes(files["manifest.template.json"], "manifest template")
    if not isinstance(manifest, dict):
        fail("manifest template must be an object")
    version = require_string(manifest.get("version"), "manifest.version", VERSION_RE)
    commit = require_string(manifest.get("commitSha"), "manifest.commitSha", COMMIT_RE)
    if manifest.get("sourceRef") != f"refs/tags/{version}":
        fail("manifest template sourceRef is not refs/tags/version")
    if manifest.get("signingKeyId") != PLACEHOLDER_KEY_ID:
        fail("manifest template placeholder signing key differs")
    match = ARTIFACT_RE.fullmatch(artifact_name)
    assert match is not None
    if match.group(1) != version or match.group(2) != commit[:12]:
        fail("artifact filename differs from manifest version/commit")
    attestation = load_json_bytes(
        files["updater-wheelhouse.attestation.json"],
        "updater wheelhouse attestation",
    )
    if not isinstance(attestation, dict):
        fail("updater wheelhouse attestation must be an object")
    return {
        "artifactName": artifact_name,
        "artifactSha256": artifact_sha,
        "candidateFiles": files,
        "commitSha": commit,
        "manifest": manifest,
        "manifestTemplateSha256": sha256_bytes(files["manifest.template.json"]),
        "publishInventorySha256": sha256_bytes(files["PUBLISH_SHA256SUMS"]),
        "updaterWheelhouseAttestationSha256": sha256_bytes(
            files["updater-wheelhouse.attestation.json"]
        ),
        "version": version,
    }


def token_from_env(name: str) -> str:
    if not re.fullmatch(r"[A-Z][A-Z0-9_]{1,63}", name):
        fail("token environment variable name is invalid")
    value = os.environ.get(name, "")
    if not value:
        fail(f"required token environment variable is empty: {name}")
    return value


def github_client(args: argparse.Namespace) -> GitHubClient:
    return GitHubClient(args.api_url, args.repository, token_from_env(args.token_env))


def command_github_gate(args: argparse.Namespace) -> None:
    validate_version(args.version)
    require_string(args.expected_main_sha, "expected_main_sha", COMMIT_RE)
    if args.confirmation != CONFIRM_BUILD:
        fail("unsigned candidate confirmation string differs")
    client = github_client(args)
    verify_main_and_tag(client, args.expected_main_sha, args.version)
    evidence = collect_main_ci(client, args.expected_main_sha)
    verify_main_and_tag(client, args.expected_main_sha, args.version)
    write_json_exclusive(
        args.output.resolve(),
        {
            "ciRuns": evidence,
            "finalMainSha": args.expected_main_sha,
            "initialMainSha": args.expected_main_sha,
            "product": PRODUCT,
            "repository": args.repository,
            "schemaVersion": 1,
            "version": args.version,
        },
    )


def validate_unsigned_workflow_run(
    workflow_run: Any,
    *,
    run_id: int,
    run_attempt: int,
    commit: str,
    require_success: bool,
) -> tuple[str, Any]:
    if not isinstance(workflow_run, dict) or workflow_run.get("id") != run_id:
        fail("unsigned workflow run metadata is missing or names another run")
    if (
        workflow_run.get("path")
        != ".github/workflows/unsigned-release-candidate.yml"
        or workflow_run.get("event") != "workflow_dispatch"
        or workflow_run.get("head_branch") != "main"
        or workflow_run.get("head_sha") != commit
        or workflow_run.get("run_attempt") != run_attempt
    ):
        fail("unsigned workflow run lineage differs")
    status = workflow_run.get("status")
    conclusion = workflow_run.get("conclusion")
    if require_success:
        if status != "completed" or conclusion != "success":
            fail("unsigned workflow is not completed/success")
    elif status not in {"in_progress", "completed"}:
        fail("unsigned workflow status is not verifiable")
    return status, conclusion


def command_verify_github_artifact(args: argparse.Namespace) -> None:
    validate_version(args.version)
    commit = require_string(args.expected_main_sha, "expected_main_sha", COMMIT_RE)
    expected_digest = require_string(args.expected_service_sha256, "expected_service_sha256", SHA256_RE)
    artifact_id = require_int(args.artifact_id, "artifact_id")
    run_id = require_int(args.workflow_run_id, "workflow_run_id")
    run_attempt = require_int(args.workflow_run_attempt, "workflow_run_attempt")
    if run_attempt != 1:
        fail("unsigned workflow run_attempt must be 1")
    client = github_client(args)
    verify_main_and_tag(client, commit, args.version)
    ci_runs = collect_main_ci(client, commit)
    workflow_run, _, _ = client.json(
        f"/repos/{client.repository}/actions/runs/{run_id}"
    )
    workflow_status, workflow_conclusion = validate_unsigned_workflow_run(
        workflow_run,
        run_id=run_id,
        run_attempt=run_attempt,
        commit=commit,
        require_success=args.require_workflow_success,
    )
    expected_name = f"uten-imp-unsigned-{commit}"
    listed = client.pages(
        f"/repos/{client.repository}/actions/runs/{run_id}/artifacts?per_page=100",
        "artifacts",
    )
    matches = [item for item in listed if item.get("name") == expected_name]
    if len(matches) != 1 or matches[0].get("id") != artifact_id:
        fail("current workflow run does not contain exactly the expected artifact")
    metadata, _, _ = client.json(f"/repos/{client.repository}/actions/artifacts/{artifact_id}")
    if not isinstance(metadata, dict) or metadata.get("expired") is not False:
        fail("GitHub artifact metadata is missing or expired")
    if metadata.get("name") != expected_name:
        fail("GitHub artifact name differs")
    workflow_run = metadata.get("workflow_run")
    if not isinstance(workflow_run, dict) or workflow_run.get("id") != run_id or workflow_run.get("head_sha") != commit:
        fail("GitHub artifact workflow lineage differs")
    service_digest = metadata.get("digest")
    if service_digest != f"sha256:{expected_digest}":
        fail("GitHub artifact service digest differs from upload output")
    size = require_int(metadata.get("size_in_bytes"), "artifact.size_in_bytes")
    archive_url = require_string(metadata.get("archive_download_url"), "artifact.archive_download_url")
    zip_raw, _headers, _status = client.request(
        archive_url,
        accept="application/octet-stream",
        allow_external_redirect=True,
    )
    if len(zip_raw) != size or sha256_bytes(zip_raw) != expected_digest:
        fail("downloaded GitHub artifact ZIP size/digest differs")
    candidate_raw, candidate_sha = candidate_tar_from_zip(zip_raw)
    candidate = verify_candidate_tar(candidate_raw)
    if candidate["version"] != args.version or candidate["commitSha"] != commit:
        fail("candidate version/commit differs from workflow inputs")
    verify_main_and_tag(client, commit, args.version)
    output_zip = args.output_zip.resolve()
    output_zip.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(output_zip, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(zip_raw)
        output.flush()
        os.fsync(output.fileno())
    write_json_exclusive(
        args.output_evidence.resolve(),
        {
            "artifact": {
                "headSha": commit,
                "id": artifact_id,
                "name": expected_name,
                "serviceSha256": expected_digest,
                "sizeBytes": size,
                "workflowRunId": run_id,
                "zipMember": "publish-candidate.tar",
                "zipMemberSha256": candidate_sha,
            },
            "capturedAtUtc": utc_now(),
            "ciRuns": ci_runs,
            "product": PRODUCT,
            "repository": args.repository,
            "schemaVersion": 1,
            "source": {
                "expectedMainSha": commit,
                "finalMainSha": commit,
                "futureSourceRef": f"refs/tags/{args.version}",
                "initialMainSha": commit,
                "remoteTagAbsentAfter": True,
                "remoteTagAbsentBefore": True,
                "version": args.version,
            },
            "workflow": {
                "path": ".github/workflows/unsigned-release-candidate.yml",
                "runAttempt": run_attempt,
                "runId": run_id,
                "sha": commit,
                "status": workflow_status,
                "conclusion": workflow_conclusion,
            },
        },
    )


def run_tool(tool: Path, expected_sha256: str, arguments: list[str]) -> None:
    require_string(expected_sha256, f"expected digest for {tool.name}", SHA256_RE)
    tool = regular_file(tool, f"pre-reviewed tool {tool.name}", max_size=MAX_JSON_BYTES)
    if sha256_file(tool) != expected_sha256:
        fail(f"pre-reviewed tool digest differs: {tool}")
    completed = subprocess.run(
        [sys.executable, "-I", str(tool), *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
        timeout=300,
    )
    if completed.returncode != 0:
        fail(f"pre-reviewed tool rejected the candidate: {tool.name}")


def command_verify_candidate(args: argparse.Namespace) -> None:
    evidence, evidence_raw = load_json(args.evidence, "GitHub candidate evidence")
    expected_evidence = require_string(
        args.expected_evidence_sha256,
        "expected_evidence_sha256",
        SHA256_RE,
    )
    if sha256_bytes(evidence_raw) != expected_evidence:
        fail("GitHub candidate evidence digest differs from the out-of-band value")
    if not isinstance(evidence, dict) or evidence.get("schemaVersion") != 1 or evidence.get("product") != PRODUCT:
        fail("GitHub candidate evidence schema/product differs")
    artifact = evidence.get("artifact")
    source = evidence.get("source")
    workflow = evidence.get("workflow")
    if not isinstance(artifact, dict) or not isinstance(source, dict) or not isinstance(workflow, dict):
        fail("GitHub candidate evidence lacks artifact/source")
    if (
        workflow.get("path") != ".github/workflows/unsigned-release-candidate.yml"
        or workflow.get("runAttempt") != 1
        or workflow.get("status") != "completed"
        or workflow.get("conclusion") != "success"
    ):
        fail("GitHub candidate evidence does not prove a successful unsigned workflow")
    zip_path = regular_file(
        args.artifact_zip, "offline artifact ZIP", max_size=MAX_ZIP_BYTES
    )
    zip_raw = zip_path.read_bytes()
    expected_service = require_string(artifact.get("serviceSha256"), "evidence artifact serviceSha256", SHA256_RE)
    if len(zip_raw) != require_int(artifact.get("sizeBytes"), "evidence artifact sizeBytes") or sha256_bytes(zip_raw) != expected_service:
        fail("offline artifact ZIP differs from captured GitHub evidence")
    candidate_raw, candidate_sha = candidate_tar_from_zip(zip_raw)
    if candidate_sha != artifact.get("zipMemberSha256"):
        fail("offline publish-candidate.tar differs from captured evidence")
    candidate = verify_candidate_tar(candidate_raw)
    version = require_string(source.get("version"), "evidence source.version", VERSION_RE)
    commit = require_string(source.get("expectedMainSha"), "evidence source.expectedMainSha", COMMIT_RE)
    if candidate["version"] != version or candidate["commitSha"] != commit:
        fail("offline candidate version/commit differs from captured evidence")
    with tempfile.TemporaryDirectory(prefix="uten-offline-verify-") as temporary:
        root = Path(temporary)
        files = candidate["candidateFiles"]
        manifest_path = root / "manifest.template.json"
        archive_path = root / candidate["artifactName"]
        manifest_path.write_bytes(files["manifest.template.json"])
        archive_path.write_bytes(files[candidate["artifactName"]])
        guard = args.release_guard
        run_tool(
            guard,
            args.expected_release_guard_sha256,
            ["validate-manifest", "--manifest", str(manifest_path), "--expected-version", version],
        )
        run_tool(
            guard,
            args.expected_release_guard_sha256,
            ["verify-bundle", "--manifest", str(manifest_path), "--archive", str(archive_path), "--destination-parent", str(root / "verified")],
        )
    write_json_exclusive(
        args.output_receipt.resolve(),
        {
            "artifactSha256": candidate["artifactSha256"],
            "commitSha": commit,
            "githubEvidenceSha256": sha256_bytes(evidence_raw),
            "manifestTemplateSha256": candidate["manifestTemplateSha256"],
            "product": PRODUCT,
            "publishCandidateSha256": candidate_sha,
            "schemaVersion": 1,
            "updaterWheelhouseAttestationSha256": candidate["updaterWheelhouseAttestationSha256"],
            "verifiedAtUtc": utc_now(),
            "version": version,
        },
    )


def fixed_executable(path: Path, expected_sha256: str, label: str) -> Path:
    require_string(expected_sha256, f"{label} expected SHA-256", SHA256_RE)
    resolved = regular_file(path, f"{label} executable")
    if sha256_file(resolved) != expected_sha256:
        fail(f"{label} executable digest differs")
    return resolved


def run_process(
    command: list[str],
    *,
    input_bytes: bytes | None = None,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    timeout: int = 300,
) -> subprocess.CompletedProcess[bytes]:
    completed = subprocess.run(
        command,
        input=input_bytes,
        cwd=cwd,
        env=env,
        stdin=None if input_bytes is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if completed.returncode != 0:
        fail(f"fixed external command failed: {Path(command[0]).name} {command[1] if len(command)>1 else ''}")
    return completed


def command_verify_source_tag(args: argparse.Namespace) -> None:
    version = require_string(args.version, "version", VERSION_RE)
    validate_version(version)
    commit = require_string(args.commit, "commit", COMMIT_RE)
    tag_key = require_string(args.expected_tag_key_id, "expected_tag_key_id", KEY_ID_RE)
    repository = regular_directory(args.git_repository, "offline Git repository")
    git = fixed_executable(args.git_bin, args.expected_git_sha256, "git")
    ssh_keygen = fixed_executable(
        args.ssh_keygen, args.expected_ssh_keygen_sha256, "ssh-keygen"
    )
    allowed = regular_file(args.allowed_signers, "offline Git allowed_signers", max_size=1024 * 1024)
    if sha256_file(allowed) != args.expected_allowed_signers_sha256:
        fail("offline Git allowed-signers digest differs")
    tag_bundle = regular_file(args.tag_bundle, "source tag bundle", max_size=MAX_ZIP_BYTES)
    with tempfile.TemporaryDirectory(prefix="uten-tag-verify-") as temporary:
        environment = {
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_OPTIONAL_LOCKS": "0",
            "HOME": temporary,
            "LC_ALL": "C",
            "PATH": "",
        }
        git_config = [
            str(git),
            "-c", "gpg.format=ssh",
            "-c", f"gpg.ssh.allowedSignersFile={allowed}",
            "-c", f"gpg.ssh.program={ssh_keygen}",
            "-c", "core.hooksPath=/dev/null",
            "-c", "core.fsmonitor=false",
            "-c", "core.untrackedCache=false",
            "-c", "fetch.writeCommitGraph=false",
            "-c", "fetch.fsckObjects=true",
            "-c", "transfer.fsckObjects=true",
            "-c", "receive.fsckObjects=true",
        ]
        reference = f"refs/tags/{version}"

        def inspect_tag(repo: Path) -> tuple[str, bytes]:
            prefix = [*git_config, "-C", str(repo)]
            object_type = run_process(
                [*prefix, "cat-file", "-t", reference], env=environment
            ).stdout.decode("ascii", "strict").strip()
            if object_type != "tag":
                fail("source tag is not an annotated tag object")
            peeled = run_process(
                [*prefix, "rev-parse", f"{reference}^{{}}"], env=environment
            ).stdout.decode("ascii", "strict").strip()
            if peeled != commit:
                fail("source tag does not peel to the expected commit")
            verified = run_process(
                [*prefix, "verify-tag", "--raw", reference],
                env=environment,
            )
            verification_text = (verified.stdout + verified.stderr).decode(
                "utf-8", "replace"
            )
            if tag_key not in verification_text:
                fail("verified source tag signature fingerprint differs")
            tag_object_value = run_process(
                [*prefix, "rev-parse", reference], env=environment
            ).stdout.decode("ascii", "strict").strip()
            require_string(tag_object_value, "tag object SHA", COMMIT_RE)
            tag_content = run_process(
                [*prefix, "cat-file", "tag", tag_object_value], env=environment
            ).stdout
            return tag_object_value, tag_content

        repository_tag_object, repository_tag_bytes = inspect_tag(repository)
        isolated = Path(temporary) / "bundle-repository.git"
        run_process(
            [*git_config, "init", "--bare", str(isolated)],
            env=environment,
        )
        isolated_prefix = [*git_config, "-C", str(isolated)]
        # Verification in a brand-new empty repository rejects thin bundles
        # whose prerequisite objects exist only in the source repository.
        run_process(
            [*isolated_prefix, "bundle", "verify", str(tag_bundle)],
            env=environment,
        )
        bundle_heads = run_process(
            [*isolated_prefix, "bundle", "list-heads", str(tag_bundle)],
            env=environment,
        ).stdout.decode("utf-8", "strict").splitlines()
        if bundle_heads != [f"{repository_tag_object} {reference}"]:
            fail("source tag bundle does not contain only the verified annotated tag object")
        run_process(
            [
                *isolated_prefix,
                "fetch",
                "--no-tags",
                str(tag_bundle),
                f"{reference}:{reference}",
            ],
            env=environment,
        )
        tag_object, tag_bytes = inspect_tag(isolated)
        if (
            tag_object != repository_tag_object
            or tag_bytes != repository_tag_bytes
        ):
            fail("isolated bundle tag differs from the offline repository tag")
    write_json_exclusive(
        args.output_receipt.resolve(),
        {
            "commitSha": commit,
            "gitAllowedSignersSha256": args.expected_allowed_signers_sha256,
            "gitTagSigningKeyId": tag_key,
            "product": PRODUCT,
            "schemaVersion": 1,
            "sourceRef": f"refs/tags/{version}",
            "tagBundleSha256": sha256_file(tag_bundle),
            "tagObjectContentSha256": sha256_bytes(tag_bytes),
            "tagObjectSha": tag_object,
            "verifiedAtUtc": utc_now(),
            "version": version,
        },
    )


def _read_candidate_zip(path: Path) -> tuple[dict[str, Any], bytes, str]:
    path = regular_file(path, "candidate ZIP", max_size=MAX_ZIP_BYTES)
    zip_raw = path.read_bytes()
    candidate_raw, candidate_sha = candidate_tar_from_zip(zip_raw)
    return verify_candidate_tar(candidate_raw), candidate_raw, candidate_sha


def verify_candidate_payload_copies(candidate: dict[str, Any]) -> None:
    version = candidate["version"]
    files = candidate["candidateFiles"]
    expected = {
        f"{version}/sbom/backend.cdx.json": (
            "backend.cdx.json",
            64 * 1024 * 1024,
        ),
        f"{version}/sbom/flutter.cdx.json": (
            "flutter.cdx.json",
            64 * 1024 * 1024,
        ),
        f"{version}/sbom/updater/updater-wheelhouse.attestation.json": (
            "updater-wheelhouse.attestation.json",
            16 * 1024 * 1024,
        ),
    }
    observed: set[str] = set()
    try:
        with tarfile.open(
            fileobj=io.BytesIO(files[candidate["artifactName"]]), mode="r:gz"
        ) as archive:
            for member in archive:
                if member.name not in expected:
                    continue
                if member.name in observed or not member.isfile():
                    fail("release archive metadata copy is duplicate or non-regular")
                observed.add(member.name)
                standalone_name, maximum = expected[member.name]
                if member.size <= 0 or member.size > maximum:
                    fail("release archive metadata copy size is invalid")
                stream = archive.extractfile(member)
                if stream is None:
                    fail("release archive metadata copy cannot be read")
                with stream:
                    raw = stream.read(maximum + 1)
                if len(raw) != member.size or raw != files[standalone_name]:
                    fail(
                        f"standalone {standalone_name} differs from the release archive payload"
                    )
    except (tarfile.TarError, EOFError) as error:
        fail(f"release archive cannot be inspected for metadata copies: {error}")
    if observed != set(expected):
        fail("release archive is missing a required standalone metadata source")


def verify_manifest_publication_copies(
    manifest: Any,
    files: dict[str, bytes],
    *,
    expected_attestation_sha256: str,
) -> None:
    if not isinstance(manifest, dict):
        fail("publication manifest must be an object")
    version = require_string(manifest.get("version"), "manifest.version", VERSION_RE)
    commit = require_string(manifest.get("commitSha"), "manifest.commitSha", COMMIT_RE)
    artifact = require_exact_keys(
        manifest.get("artifact"),
        {"fileName", "objectKey", "sha256", "sizeBytes"},
        "manifest.artifact",
    )
    artifact_name = require_string(
        artifact["fileName"], "manifest.artifact.fileName", ARTIFACT_RE
    )
    match = ARTIFACT_RE.fullmatch(artifact_name)
    assert match is not None
    if match.group(1) != version or match.group(2) != commit[:12]:
        fail("manifest artifact filename differs from manifest lineage")
    artifact_sha = require_string(
        artifact["sha256"], "manifest.artifact.sha256", SHA256_RE
    )
    artifact_size = require_int(
        artifact["sizeBytes"], "manifest.artifact.sizeBytes"
    )
    artifact_raw = files.get(artifact_name)
    if (
        artifact_raw is None
        or len(artifact_raw) != artifact_size
        or sha256_bytes(artifact_raw) != artifact_sha
    ):
        fail("publication artifact bytes differ from the signed manifest")
    sidecar = files.get(f"{artifact_name}.sha256")
    if sidecar != f"{artifact_sha}  {artifact_name}\n".encode("ascii"):
        fail("publication artifact sidecar differs from the signed manifest")

    sbom = require_exact_keys(
        manifest.get("sbom"), {"backend", "flutter", "format"}, "manifest.sbom"
    )
    if sbom["format"] != "CycloneDX":
        fail("manifest SBOM format differs")
    for component, local_name, payload_path in (
        ("backend", "backend.cdx.json", "sbom/backend.cdx.json"),
        ("flutter", "flutter.cdx.json", "sbom/flutter.cdx.json"),
    ):
        entry = require_exact_keys(
            sbom[component], {"path", "sha256"}, f"manifest.sbom.{component}"
        )
        if entry["path"] != payload_path:
            fail(f"manifest.sbom.{component}.path differs")
        expected_sha = require_string(
            entry["sha256"], f"manifest.sbom.{component}.sha256", SHA256_RE
        )
        raw = files.get(local_name)
        if raw is None or sha256_bytes(raw) != expected_sha:
            fail(f"standalone {component} SBOM differs from the signed manifest")

    expected_attestation = require_string(
        expected_attestation_sha256,
        "expected updater attestation SHA-256",
        SHA256_RE,
    )
    attestation = files.get("updater-wheelhouse.attestation.json")
    if (
        attestation is None
        or sha256_bytes(attestation) != expected_attestation
    ):
        fail("standalone updater attestation differs from signed lineage evidence")


def command_prepare_publication(args: argparse.Namespace) -> None:
    candidate, _candidate_raw, candidate_sha = _read_candidate_zip(args.artifact_zip)
    verify_candidate_payload_copies(candidate)
    verify_manifest_publication_copies(
        candidate["manifest"],
        candidate["candidateFiles"],
        expected_attestation_sha256=candidate[
            "updaterWheelhouseAttestationSha256"
        ],
    )
    receipt, receipt_raw = load_json(args.candidate_receipt, "verified candidate receipt")
    tag_receipt, tag_raw = load_json(args.tag_receipt, "source tag receipt")
    if not isinstance(receipt, dict) or not isinstance(tag_receipt, dict):
        fail("candidate/tag receipt must be objects")
    version = candidate["version"]
    commit = candidate["commitSha"]
    if receipt.get("schemaVersion") != 1 or receipt.get("product") != PRODUCT:
        fail("verified candidate receipt schema/product differs")
    if receipt.get("version") != version or receipt.get("commitSha") != commit or receipt.get("publishCandidateSha256") != candidate_sha:
        fail("verified candidate receipt differs from candidate ZIP")
    if receipt.get("manifestTemplateSha256") != candidate["manifestTemplateSha256"] or receipt.get("updaterWheelhouseAttestationSha256") != candidate["updaterWheelhouseAttestationSha256"]:
        fail("verified candidate receipt metadata digest differs")
    if tag_receipt.get("schemaVersion") != 1 or tag_receipt.get("product") != PRODUCT:
        fail("source tag receipt schema/product differs")
    if tag_receipt.get("version") != version or tag_receipt.get("commitSha") != commit or tag_receipt.get("sourceRef") != f"refs/tags/{version}":
        fail("source tag receipt differs from candidate lineage")
    tag_key = require_string(
        tag_receipt.get("gitTagSigningKeyId"),
        "tag receipt gitTagSigningKeyId",
        KEY_ID_RE,
    )
    release_key = require_string(args.release_key_id, "release_key_id", KEY_ID_RE)
    if release_key == PLACEHOLDER_KEY_ID or release_key == tag_key:
        fail("release key must be real and different from the Git tag key")
    template = dict(candidate["manifest"])
    if template.get("signingKeyId") != PLACEHOLDER_KEY_ID:
        fail("candidate manifest placeholder is missing")
    template["signingKeyId"] = release_key
    manifest_raw = canonical_json_bytes(template)
    published_at = require_string(args.published_at_utc, "published_at_utc")
    try:
        dt.datetime.strptime(published_at, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        fail(f"published_at_utc is invalid: {error}")
    channel = {
        "channel": "candidate",
        "commitSha": commit,
        "manifest": {
            "objectKey": f"releases/{version}/manifest.json",
            "sha256": sha256_bytes(manifest_raw),
            "signatureObjectKey": f"releases/{version}/manifest.sig",
        },
        "product": PRODUCT,
        "publishedAtUtc": published_at,
        "releaseSequence": validate_version(version),
        "schemaVersion": 1,
        "signingKeyId": release_key,
        "version": version,
    }
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    files = candidate["candidateFiles"]
    for name in (
        candidate["artifactName"],
        f"{candidate['artifactName']}.sha256",
        "backend.cdx.json",
        "flutter.cdx.json",
        "updater-wheelhouse.attestation.json",
    ):
        (output / name).write_bytes(files[name])
    (output / "manifest.json").write_bytes(manifest_raw)
    (output / "channel.json").write_bytes(canonical_json_bytes(channel))
    write_json_exclusive(
        output / "publication-inputs.json",
        {
            "candidateReceiptSha256": sha256_bytes(receipt_raw),
            "channelSha256": sha256_file(output / "channel.json"),
            "commitSha": commit,
            "gitTagSigningKeyId": tag_receipt.get("gitTagSigningKeyId"),
            "githubEvidenceSha256": receipt.get("githubEvidenceSha256"),
            "manifestTemplateSha256": receipt.get("manifestTemplateSha256"),
            "manifestSha256": sha256_file(output / "manifest.json"),
            "product": PRODUCT,
            "publishCandidateSha256": candidate_sha,
            "releaseArtifactSigningKeyId": release_key,
            "schemaVersion": 1,
            "sourceTagBundleSha256": tag_receipt.get("tagBundleSha256"),
            "sourceTagObjectSha": tag_receipt.get("tagObjectSha"),
            "sourceTagReceiptSha256": sha256_bytes(tag_raw),
            "updaterWheelhouseAttestationSha256": candidate["updaterWheelhouseAttestationSha256"],
            "version": version,
        },
    )


def _ssh_sign(ssh_keygen: Path, private_key: Path, namespace: str, source: Path, destination: Path) -> None:
    generated = Path(str(source) + ".sig")
    if generated.exists() or destination.exists():
        fail("detached signature output already exists")
    run_process([str(ssh_keygen), "-Y", "sign", "-f", str(private_key), "-n", namespace, str(source)])
    if not generated.is_file() or generated.is_symlink():
        fail("ssh-keygen did not create the expected detached signature")
    generated.replace(destination)


def _selected_allowed_signer(
    ssh_keygen: Path, allowed: Path, expected_key_id: str
) -> bytes:
    require_string(expected_key_id, "expected signing key ID", KEY_ID_RE)
    matches: list[bytes] = []
    seen: set[bytes] = set()
    for raw_line in allowed.read_bytes().splitlines():
        if not raw_line or raw_line in seen:
            fail("allowed_signers contains an empty or duplicate line")
        seen.add(raw_line)
        fields = raw_line.split()
        if len(fields) != 3 or fields[0] != SIGNER_IDENTITY.encode() or fields[1] != b"ssh-ed25519":
            fail("allowed_signers line is not canonical for the Release identity")
        with tempfile.NamedTemporaryFile(prefix="uten-allowed-public-", delete=False) as temporary:
            temporary.write(fields[1] + b" " + fields[2] + b"\n")
            public = Path(temporary.name)
        try:
            output = run_process(
                [str(ssh_keygen), "-E", "sha256", "-lf", str(public)]
            ).stdout.decode("utf-8", "strict").split()
        finally:
            public.unlink(missing_ok=True)
        if len(output) < 2:
            fail("ssh-keygen fingerprint output is malformed")
        if output[1] == expected_key_id:
            matches.append(raw_line + b"\n")
    if len(matches) != 1:
        fail("allowed_signers does not select exactly the expected Release key")
    return matches[0]


def _ssh_verify(
    ssh_keygen: Path,
    allowed: Path,
    namespace: str,
    source: Path,
    signature: Path,
    expected_key_id: str,
) -> None:
    selected = _selected_allowed_signer(ssh_keygen, allowed, expected_key_id)
    with tempfile.NamedTemporaryFile(prefix="uten-selected-signer-", delete=False) as temporary:
        temporary.write(selected)
        selected_path = Path(temporary.name)
    try:
        run_process(
            [str(ssh_keygen), "-Y", "verify", "-f", str(selected_path), "-I", SIGNER_IDENTITY, "-n", namespace, "-s", str(signature)],
            input_bytes=source.read_bytes(),
        )
    finally:
        selected_path.unlink(missing_ok=True)


def command_sign_publication(args: argparse.Namespace) -> None:
    root = regular_directory(args.publication_dir, "publication directory")
    inputs, inputs_raw = load_json(root / "publication-inputs.json", "publication inputs")
    inputs = require_exact_keys(inputs, PUBLICATION_INPUT_KEYS, "publication inputs")
    if inputs.get("schemaVersion") != 1 or inputs.get("product") != PRODUCT:
        fail("publication inputs schema differs")
    expected_inputs = require_string(
        args.expected_publication_inputs_sha256,
        "expected_publication_inputs_sha256",
        SHA256_RE,
    )
    if sha256_bytes(inputs_raw) != expected_inputs:
        fail("publication inputs digest differs from the out-of-band approval")
    ssh_keygen = fixed_executable(args.ssh_keygen, args.expected_ssh_keygen_sha256, "ssh-keygen")
    signing_material = regular_file(
        args.private_key,
        "offline Release signing material",
        max_size=1024 * 1024,
    )
    if os.name == "posix" and stat.S_IMODE(signing_material.stat().st_mode) & 0o077:
        fail("offline Release private key must not be group/world accessible")
    allowed = regular_file(args.allowed_signers, "Release allowed_signers", max_size=1024 * 1024)
    if sha256_file(allowed) != args.expected_allowed_signers_sha256:
        fail("Release allowed-signers digest differs")
    public = run_process([str(ssh_keygen), "-y", "-f", str(signing_material)]).stdout
    with tempfile.NamedTemporaryFile(prefix="uten-release-public-", delete=False) as temporary:
        temporary.write(public)
        public_path = Path(temporary.name)
    try:
        fingerprint = run_process([str(ssh_keygen), "-E", "sha256", "-lf", str(public_path)]).stdout.decode("utf-8", "strict").split()[1]
    finally:
        public_path.unlink(missing_ok=True)
    if fingerprint != inputs.get("releaseArtifactSigningKeyId"):
        fail("offline Release private key fingerprint differs from publication inputs")
    decision = regular_file(args.decision, "release decision", max_size=MAX_JSON_BYTES)
    validator = args.decision_validator
    run_tool(
        validator,
        args.expected_decision_validator_sha256,
        [
            "validate", "--decision", str(decision),
            "--expected-version", inputs["version"],
            "--expected-commit", inputs["commitSha"],
            "--expected-manifest-sha256", inputs["manifestSha256"],
            "--expected-channel-sha256", inputs["channelSha256"],
            "--expected-candidate-receipt-sha256", inputs["candidateReceiptSha256"],
            "--expected-github-evidence-sha256", inputs["githubEvidenceSha256"],
            "--expected-manifest-template-sha256", inputs["manifestTemplateSha256"],
            "--expected-publish-candidate-sha256", inputs["publishCandidateSha256"],
            "--expected-source-tag-bundle-sha256", inputs["sourceTagBundleSha256"],
            "--expected-source-tag-object-sha", inputs["sourceTagObjectSha"],
            "--expected-updater-attestation-sha256", inputs["updaterWheelhouseAttestationSha256"],
            "--expected-release-key-id", inputs["releaseArtifactSigningKeyId"],
            "--expected-tag-key-id", inputs["gitTagSigningKeyId"],
        ],
    )
    decision_target = root / "release-decision.json"
    if decision_target.exists():
        fail("release-decision.json already exists")
    decision_target.write_bytes(decision.read_bytes())
    _ssh_sign(ssh_keygen, signing_material, RELEASE_NAMESPACE, root / "manifest.json", root / "manifest.sig")
    _ssh_sign(ssh_keygen, signing_material, RELEASE_NAMESPACE, root / "channel.json", root / "channel.sig")
    _ssh_sign(
        ssh_keygen,
        signing_material,
        WHEELHOUSE_NAMESPACE,
        root / "updater-wheelhouse.attestation.json",
        root / "updater-wheelhouse.attestation.sig",
    )
    _ssh_sign(ssh_keygen, signing_material, DECISION_NAMESPACE, decision_target, root / "release-decision.sig")
    for source, signature, namespace in (
        (root / "manifest.json", root / "manifest.sig", RELEASE_NAMESPACE),
        (root / "channel.json", root / "channel.sig", RELEASE_NAMESPACE),
        (root / "updater-wheelhouse.attestation.json", root / "updater-wheelhouse.attestation.sig", WHEELHOUSE_NAMESPACE),
        (decision_target, root / "release-decision.sig", DECISION_NAMESPACE),
    ):
        _ssh_verify(ssh_keygen, allowed, namespace, source, signature, fingerprint)
    write_json_exclusive(
        root / "offline-signing-receipt.json",
        {
            "allowedSignersSha256": args.expected_allowed_signers_sha256,
            "decisionSha256": sha256_file(decision_target),
            "publicationInputsSha256": sha256_bytes(inputs_raw),
            "releaseArtifactSigningKeyId": fingerprint,
            "schemaVersion": 1,
            "signedAtUtc": utc_now(),
            "version": inputs["version"],
        },
    )


def _publication_signature_contract(root: Path) -> list[tuple[Path, Path, str]]:
    return [
        (root / "manifest.json", root / "manifest.sig", RELEASE_NAMESPACE),
        (root / "channel.json", root / "channel.sig", RELEASE_NAMESPACE),
        (
            root / "updater-wheelhouse.attestation.json",
            root / "updater-wheelhouse.attestation.sig",
            WHEELHOUSE_NAMESPACE,
        ),
        (root / "release-decision.json", root / "release-decision.sig", DECISION_NAMESPACE),
    ]


def command_verify_publication(args: argparse.Namespace) -> None:
    root = regular_directory(args.publication_dir, "publication directory")
    inputs, _ = load_json(root / "publication-inputs.json", "publication inputs")
    inputs = require_exact_keys(inputs, PUBLICATION_INPUT_KEYS, "publication inputs")
    if inputs.get("schemaVersion") != 1 or inputs.get("product") != PRODUCT:
        fail("publication inputs schema differs")
    if args.expected_tag_key_id != inputs.get("gitTagSigningKeyId"):
        fail("independently supplied Git tag key differs from publication inputs")
    allowed = regular_file(args.allowed_signers, "Release allowed_signers", max_size=1024 * 1024)
    if sha256_file(allowed) != args.expected_allowed_signers_sha256:
        fail("Release allowed-signers digest differs")
    ssh_keygen = fixed_executable(args.ssh_keygen, args.expected_ssh_keygen_sha256, "ssh-keygen")
    for source, signature, namespace in _publication_signature_contract(root):
        source = regular_file(source, f"signed publication {source.name}", max_size=MAX_TAR_MEMBER_BYTES)
        signature = regular_file(signature, f"signed publication {signature.name}", max_size=1024 * 1024)
        _ssh_verify(
            ssh_keygen,
            allowed,
            namespace,
            source,
            signature,
            inputs["releaseArtifactSigningKeyId"],
        )
    manifest, manifest_raw = load_json(root / "manifest.json", "signed manifest")
    channel, channel_raw = load_json(root / "channel.json", "signed channel")
    if not isinstance(manifest, dict) or not isinstance(channel, dict):
        fail("signed manifest/channel must be objects")
    version = require_string(manifest.get("version"), "manifest.version", VERSION_RE)
    commit = require_string(manifest.get("commitSha"), "manifest.commitSha", COMMIT_RE)
    if channel.get("version") != version or channel.get("commitSha") != commit:
        fail("signed channel lineage differs from manifest")
    if channel.get("signingKeyId") != manifest.get("signingKeyId") or channel.get("manifest", {}).get("sha256") != sha256_bytes(manifest_raw):
        fail("signed channel key/manifest digest differs")
    if sha256_bytes(manifest_raw) != inputs.get("manifestSha256") or sha256_bytes(channel_raw) != inputs.get("channelSha256"):
        fail("signed manifest/channel differ from publication inputs")
    guard = args.release_guard
    artifact_names = [path for path in root.iterdir() if ARTIFACT_RE.fullmatch(path.name)]
    if len(artifact_names) != 1:
        fail("publication directory must contain one release artifact")
    parity_names = {
        artifact_names[0].name,
        f"{artifact_names[0].name}.sha256",
        "backend.cdx.json",
        "flutter.cdx.json",
        "updater-wheelhouse.attestation.json",
    }
    parity_files = {
        name: regular_file(
            root / name,
            f"publication source {name}",
            max_size=MAX_TAR_MEMBER_BYTES,
        ).read_bytes()
        for name in parity_names
    }
    verify_manifest_publication_copies(
        manifest,
        parity_files,
        expected_attestation_sha256=inputs[
            "updaterWheelhouseAttestationSha256"
        ],
    )
    run_tool(
        guard,
        args.expected_release_guard_sha256,
        ["validate-manifest", "--manifest", str(root / "manifest.json"), "--expected-version", version, "--expected-signing-key-id", manifest["signingKeyId"]],
    )
    with tempfile.TemporaryDirectory(prefix="uten-publication-verify-") as temporary:
        run_tool(
            guard,
            args.expected_release_guard_sha256,
            ["verify-bundle", "--manifest", str(root / "manifest.json"), "--archive", str(artifact_names[0]), "--destination-parent", temporary],
        )
    decision_validator = args.decision_validator
    run_tool(
        decision_validator,
        args.expected_decision_validator_sha256,
        [
            "validate", "--decision", str(root / "release-decision.json"),
            "--expected-version", version,
            "--expected-commit", commit,
            "--expected-manifest-sha256", inputs["manifestSha256"],
            "--expected-channel-sha256", inputs["channelSha256"],
            "--expected-candidate-receipt-sha256", inputs["candidateReceiptSha256"],
            "--expected-github-evidence-sha256", inputs["githubEvidenceSha256"],
            "--expected-manifest-template-sha256", inputs["manifestTemplateSha256"],
            "--expected-publish-candidate-sha256", inputs["publishCandidateSha256"],
            "--expected-source-tag-bundle-sha256", inputs["sourceTagBundleSha256"],
            "--expected-source-tag-object-sha", inputs["sourceTagObjectSha"],
            "--expected-updater-attestation-sha256", inputs["updaterWheelhouseAttestationSha256"],
            "--expected-release-key-id", inputs["releaseArtifactSigningKeyId"],
            "--expected-tag-key-id", inputs["gitTagSigningKeyId"],
        ],
    )
    publish_names = {
        artifact_names[0].name,
        f"{artifact_names[0].name}.sha256",
        "backend.cdx.json",
        "channel.json",
        "channel.sig",
        "flutter.cdx.json",
        "manifest.json",
        "manifest.sig",
        "release-decision.json",
        "release-decision.sig",
        "updater-wheelhouse.attestation.json",
        "updater-wheelhouse.attestation.sig",
    }
    publication_snapshot = {
        name: regular_file(
            root / name,
            f"signed publication member {name}",
            max_size=MAX_TAR_MEMBER_BYTES,
        ).read_bytes()
        for name in publish_names
    }
    if (
        publication_snapshot["manifest.json"] != manifest_raw
        or publication_snapshot["channel.json"] != channel_raw
    ):
        fail("signed manifest/channel changed during publication verification")
    verify_manifest_publication_copies(
        manifest,
        publication_snapshot,
        expected_attestation_sha256=inputs[
            "updaterWheelhouseAttestationSha256"
        ],
    )
    inventory = "".join(
        f"{sha256_bytes(publication_snapshot[name])}  {name}\n"
        for name in sorted(publish_names)
    ).encode("utf-8")
    sums = root / "SIGNED_SHA256SUMS"
    if sums.exists():
        fail("SIGNED_SHA256SUMS already exists")
    write_bytes_exclusive(sums, inventory)
    publication_snapshot[sums.name] = inventory
    publish_names.add(sums.name)
    output_tar = args.output_tar.resolve()
    if output_tar.exists():
        fail("signed publication tar already exists")
    with tarfile.open(output_tar, mode="w:", format=tarfile.PAX_FORMAT) as archive:
        for name in sorted(publish_names):
            raw = publication_snapshot[name]
            info = tarfile.TarInfo(name)
            info.size = len(raw)
            info.mode = 0o644
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            archive.addfile(info, io.BytesIO(raw))
    write_json_exclusive(
        args.output_receipt.resolve(),
        {
            "allowedSignersSha256": args.expected_allowed_signers_sha256,
            "candidateReceiptSha256": inputs["candidateReceiptSha256"],
            "channelSha256": inputs["channelSha256"],
            "commitSha": commit,
            "decisionSha256": sha256_bytes(
                publication_snapshot["release-decision.json"]
            ),
            "gitTagSigningKeyId": inputs["gitTagSigningKeyId"],
            "githubEvidenceSha256": inputs["githubEvidenceSha256"],
            "manifestTemplateSha256": inputs["manifestTemplateSha256"],
            "manifestSha256": inputs["manifestSha256"],
            "product": PRODUCT,
            "publishCandidateSha256": inputs["publishCandidateSha256"],
            "releaseArtifactSigningKeyId": inputs["releaseArtifactSigningKeyId"],
            "schemaVersion": 1,
            "signedPublicationSha256": sha256_file(output_tar),
            "sourceTagBundleSha256": inputs["sourceTagBundleSha256"],
            "sourceTagObjectSha": inputs["sourceTagObjectSha"],
            "updaterWheelhouseAttestationSha256": inputs["updaterWheelhouseAttestationSha256"],
            "verifiedAtUtc": utc_now(),
            "version": version,
        },
    )


def read_publication_tar(path: Path) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    total = 0
    try:
        with tarfile.open(path, mode="r:") as archive:
            for member in archive.getmembers():
                if not member.isfile() or "/" in member.name or "\\" in member.name or member.name in files:
                    fail("signed publication tar contains unsafe/duplicate members")
                if member.size <= 0 or member.size > MAX_TAR_MEMBER_BYTES:
                    fail("signed publication member size is invalid")
                total += member.size
                if total > MAX_TAR_TOTAL_BYTES:
                    fail("signed publication expanded size exceeds the limit")
                stream = archive.extractfile(member)
                if stream is None:
                    fail("signed publication member cannot be read")
                files[member.name] = stream.read()
    except (tarfile.TarError, EOFError) as error:
        fail(f"signed publication tar is invalid: {error}")
    required = set(SIGNED_PUBLICATION_FIXED_MEMBERS)
    artifacts = [name for name in files if ARTIFACT_RE.fullmatch(name)]
    if len(artifacts) != 1:
        fail("signed publication tar must contain one artifact")
    required |= {artifacts[0], f"{artifacts[0]}.sha256"}
    if set(files) != required:
        fail("signed publication tar exact member set differs")
    inventory = parse_sha256_inventory(files["SIGNED_SHA256SUMS"], required - {"SIGNED_SHA256SUMS"})
    for name, digest in inventory.items():
        if sha256_bytes(files[name]) != digest:
            fail(f"signed publication member digest differs: {name}")
    return files


def command_plan_oss(args: argparse.Namespace) -> None:
    publication_path = regular_file(
        args.signed_publication,
        "signed publication tar",
        max_size=MAX_TAR_TOTAL_BYTES,
    )
    files = read_publication_tar(publication_path)
    receipt, _ = load_json(args.publication_receipt, "publication receipt")
    if not isinstance(receipt, dict) or receipt.get("schemaVersion") != 1 or receipt.get("product") != PRODUCT:
        fail("publication receipt schema/product differs")
    if receipt.get("signedPublicationSha256") != sha256_file(publication_path):
        fail("publication receipt differs from signed publication tar")
    channel = load_json_bytes(files["channel.json"], "signed channel")
    manifest = load_json_bytes(files["manifest.json"], "signed manifest")
    if not isinstance(channel, dict) or not isinstance(manifest, dict):
        fail("signed channel/manifest must be objects")
    verify_manifest_publication_copies(
        manifest,
        files,
        expected_attestation_sha256=require_string(
            receipt.get("updaterWheelhouseAttestationSha256"),
            "publication receipt updater attestation SHA-256",
            SHA256_RE,
        ),
    )
    version = require_string(channel.get("version"), "channel.version", VERSION_RE)
    sequence = require_int(channel.get("releaseSequence"), "channel.releaseSequence")
    commit = require_string(channel.get("commitSha"), "channel.commitSha", COMMIT_RE)
    if manifest.get("version") != version or manifest.get("commitSha") != commit:
        fail("signed manifest/channel lineage differs")
    if channel.get("manifest", {}).get("sha256") != sha256_bytes(files["manifest.json"]):
        fail("signed channel manifest digest differs")
    if receipt.get("version") != version or receipt.get("commitSha") != commit:
        fail("publication receipt lineage differs")
    if receipt.get("manifestSha256") != sha256_bytes(files["manifest.json"]) or receipt.get("channelSha256") != sha256_bytes(files["channel.json"]):
        fail("publication receipt manifest/channel digest differs")
    allowed = regular_file(args.allowed_signers, "Release allowed_signers", max_size=1024 * 1024)
    if sha256_file(allowed) != args.expected_allowed_signers_sha256:
        fail("publication allowed-signers digest differs")
    ssh_keygen = fixed_executable(
        args.ssh_keygen, args.expected_ssh_keygen_sha256, "ssh-keygen"
    )
    with tempfile.TemporaryDirectory(prefix="uten-plan-signature-") as temporary:
        signature_root = Path(temporary)
        for name in (
            "manifest.json", "manifest.sig", "channel.json", "channel.sig",
            "updater-wheelhouse.attestation.json", "updater-wheelhouse.attestation.sig",
            "release-decision.json", "release-decision.sig",
        ):
            (signature_root / name).write_bytes(files[name])
        for source, signature, namespace in _publication_signature_contract(signature_root):
            _ssh_verify(
                ssh_keygen,
                allowed,
                namespace,
                source,
                signature,
                receipt["releaseArtifactSigningKeyId"],
            )
        artifact_names = [name for name in files if ARTIFACT_RE.fullmatch(name)]
        if len(artifact_names) != 1:
            fail("signed publication has no unique artifact")
        artifact_path = signature_root / artifact_names[0]
        artifact_path.write_bytes(files[artifact_names[0]])
        release_guard = args.release_guard
        run_tool(
            release_guard,
            args.expected_release_guard_sha256,
            [
                "validate-manifest", "--manifest", str(signature_root / "manifest.json"),
                "--expected-version", version,
                "--expected-signing-key-id", receipt["releaseArtifactSigningKeyId"],
            ],
        )
        run_tool(
            release_guard,
            args.expected_release_guard_sha256,
            [
                "verify-bundle", "--manifest", str(signature_root / "manifest.json"),
                "--archive", str(artifact_path),
                "--destination-parent", str(signature_root / "verified"),
            ],
        )
        decision_validator = args.decision_validator
        run_tool(
            decision_validator,
            args.expected_decision_validator_sha256,
            [
                "validate", "--decision", str(signature_root / "release-decision.json"),
                "--expected-version", version,
                "--expected-commit", commit,
                "--expected-manifest-sha256", receipt["manifestSha256"],
                "--expected-channel-sha256", receipt["channelSha256"],
                "--expected-candidate-receipt-sha256", receipt["candidateReceiptSha256"],
                "--expected-github-evidence-sha256", receipt["githubEvidenceSha256"],
                "--expected-manifest-template-sha256", receipt["manifestTemplateSha256"],
                "--expected-publish-candidate-sha256", receipt["publishCandidateSha256"],
                "--expected-source-tag-bundle-sha256", receipt["sourceTagBundleSha256"],
                "--expected-source-tag-object-sha", receipt["sourceTagObjectSha"],
                "--expected-updater-attestation-sha256", receipt["updaterWheelhouseAttestationSha256"],
                "--expected-release-key-id", receipt["releaseArtifactSigningKeyId"],
                "--expected-tag-key-id", receipt["gitTagSigningKeyId"],
            ],
        )
    bootstrap = args.current_pointer is None
    old_pointer_raw: bytes | None = None
    if bootstrap:
        if any(
            value is not None
            for value in (args.current_channel, args.current_channel_signature)
        ):
            fail("bootstrap must not supply partial current pointer evidence")
        if args.confirmation != CONFIRM_BOOTSTRAP:
            fail("first pointer bootstrap requires its independent exact confirmation")
    else:
        if args.current_channel is None or args.current_channel_signature is None:
            fail("ordinary publication requires current pointer/channel/signature")
        if args.confirmation != CONFIRM_OSS:
            fail("ordinary publication confirmation string differs")
        pointer_path = regular_file(args.current_pointer, "current LATEST pointer", max_size=128)
        old_pointer_raw = pointer_path.read_bytes()
        pointer = old_pointer_raw.decode("utf-8", "strict")
        if not re.fullmatch(r"v20[0-9]{2}\.[0-9]{2}\.[0-9]{2}-[1-9][0-9]{0,2}\n", pointer):
            fail("current LATEST pointer is malformed")
        current_channel = regular_file(args.current_channel, "current signed channel", max_size=MAX_JSON_BYTES)
        current_signature = regular_file(args.current_channel_signature, "current channel signature", max_size=1024 * 1024)
        old = load_json(current_channel, "current signed channel")[0]
        if not isinstance(old, dict):
            fail("current signed channel must be an object")
        old_key = require_string(old.get("signingKeyId"), "current channel signingKeyId", KEY_ID_RE)
        _ssh_verify(
            ssh_keygen,
            allowed,
            RELEASE_NAMESPACE,
            current_channel,
            current_signature,
            old_key,
        )
        if old_key != receipt["releaseArtifactSigningKeyId"]:
            fail("Release key rotation is not authorized by this exception")
        if old.get("version") != pointer.strip() or require_int(old.get("releaseSequence"), "current releaseSequence") >= sequence:
            fail("new release sequence is not strictly greater than current")
    operations: list[dict[str, Any]] = []
    for name in sorted(files):
        key = publication_object_key(version, name)
        operations.append(
            {
                "createOnly": True,
                "localName": name,
                "objectKey": key,
                "sha256": sha256_bytes(files[name]),
                "sizeBytes": len(files[name]),
            }
        )
    operations.append(
        {
            "contentBase64": __import__("base64").b64encode(f"{version}\n".encode()).decode(),
            "createOnly": bootstrap,
            "objectKey": "channels/candidate/LATEST.txt",
            "sha256": sha256_bytes(f"{version}\n".encode()),
            "sizeBytes": len(f"{version}\n".encode()),
        }
    )
    write_json_exclusive(
        args.output_plan.resolve(),
        {
            "bootstrap": bootstrap,
            "bucket": require_bucket(args.bucket),
            "endpoint": require_oss_endpoint(args.endpoint),
            "expectedOldPointerBase64": (
                None
                if old_pointer_raw is None
                else __import__("base64").b64encode(old_pointer_raw).decode()
            ),
            "expectedOldPointerSha256": (
                None if old_pointer_raw is None else sha256_bytes(old_pointer_raw)
            ),
            "operations": operations,
            "product": PRODUCT,
            "region": require_oss_region(args.region),
            "schemaVersion": 1,
            "signedPublicationSha256": sha256_file(publication_path),
            "version": version,
        },
    )


def oss_read_object(
    ossutil: Path,
    *,
    bucket: str,
    object_key: str,
    endpoint: str,
    region: str,
    environment: dict[str, str],
    max_bytes: int,
) -> bytes | None:
    if max_bytes <= 0 or max_bytes > MAX_TAR_MEMBER_BYTES:
        fail("OSS read bound is outside the permitted range")
    command = [
        str(ossutil),
        "api",
        "get-object",
        "--endpoint",
        endpoint,
        "--region",
        region,
        "--addressing-style",
        "virtual",
        "--bucket",
        bucket,
        "--key",
        object_key,
        "--output-format",
        "raw",
        "--quiet",
    ]
    output_path: Path | None = None
    error_path: Path | None = None
    process: subprocess.Popen[bytes] | None = None
    try:
        with tempfile.NamedTemporaryFile(
            prefix="uten-oss-object-",
            dir=environment["HOME"],
            delete=False,
        ) as output, tempfile.NamedTemporaryFile(
            prefix="uten-oss-error-",
            dir=environment["HOME"],
            delete=False,
        ) as error:
            output_path = Path(output.name)
            error_path = Path(error.name)
            process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=output,
                stderr=error,
                env=environment,
            )
            deadline = time.monotonic() + 300
            while process.poll() is None:
                if (
                    os.fstat(output.fileno()).st_size > max_bytes
                    or os.fstat(error.fileno()).st_size
                    > MAX_OSS_DIAGNOSTIC_BYTES
                ):
                    process.kill()
                    process.wait(timeout=5)
                    fail("OSS read exceeded its explicit byte bound")
                if time.monotonic() >= deadline:
                    process.kill()
                    process.wait(timeout=5)
                    fail("OSS read timed out")
                time.sleep(0.05)
            returncode = process.returncode
            if (
                os.fstat(output.fileno()).st_size > max_bytes
                or os.fstat(error.fileno()).st_size > MAX_OSS_DIAGNOSTIC_BYTES
            ):
                fail("OSS read exceeded its explicit byte bound")
        assert output_path is not None and error_path is not None
        if returncode == 0:
            return output_path.read_bytes()
        with output_path.open("rb") as output, error_path.open("rb") as error:
            diagnostic_raw = output.read(MAX_OSS_DIAGNOSTIC_BYTES) + error.read(
                MAX_OSS_DIAGNOSTIC_BYTES
            )
        diagnostic = diagnostic_raw.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError) as error:
        if process is not None and process.poll() is None:
            process.kill()
        fail(f"OSS read process failed safely: {error}")
    finally:
        if output_path is not None:
            output_path.unlink(missing_ok=True)
        if error_path is not None:
            error_path.unlink(missing_ok=True)
    if any(
        marker in diagnostic
        for marker in ("StatusCode=404", "status code: 404", "NoSuchKey", "ObjectNotExist")
    ):
        return None
    fail("OSS read failed without a definitive not-found result")


def oss_put_object(
    ossutil: Path,
    source: Path,
    *,
    bucket: str,
    object_key: str,
    endpoint: str,
    region: str,
    environment: dict[str, str],
    create_only: bool,
    no_store: bool = False,
) -> None:
    command = [
        str(ossutil),
        "api",
        "put-object",
        "--endpoint",
        endpoint,
        "--region",
        region,
        "--addressing-style",
        "virtual",
        "--bucket",
        bucket,
        "--key",
        object_key,
        "--body",
        source.resolve().as_uri(),
    ]
    if create_only:
        command.extend(["--forbid-overwrite", "true"])
    if no_store:
        command.extend(["--cache-control", "no-store"])
    run_process(command, env=environment, timeout=300)


def minimal_oss_environment(home: Path) -> dict[str, str]:
    return {
        "HOME": str(home),
        "LANG": "C",
        "LC_ALL": "C",
        "OSS_ACCESS_KEY_ID": os.environ["OSS_ACCESS_KEY_ID"],
        "OSS_ACCESS_KEY_SECRET": os.environ["OSS_ACCESS_KEY_SECRET"],
        "OSS_SESSION_TOKEN": os.environ["OSS_SESSION_TOKEN"],
        "PATH": "",
    }


def command_apply_oss(args: argparse.Namespace) -> None:
    plan, plan_raw = load_json(args.plan, "OSS publication plan")
    plan = require_exact_keys(
        plan,
        {
            "bootstrap", "bucket", "endpoint", "expectedOldPointerBase64",
            "expectedOldPointerSha256", "operations", "product", "schemaVersion",
            "signedPublicationSha256", "region", "version",
        },
        "OSS publication plan",
    )
    if plan["schemaVersion"] != 1 or plan["product"] != PRODUCT:
        fail("OSS publication plan schema/product differs")
    expected_plan = require_string(args.expected_plan_sha256, "expected_plan_sha256", SHA256_RE)
    if sha256_bytes(plan_raw) != expected_plan:
        fail("OSS publication plan digest differs from explicit approval")
    if type(plan["bootstrap"]) is not bool:
        fail("OSS plan bootstrap must be a boolean")
    bootstrap = plan["bootstrap"]
    version = require_string(plan["version"], "plan.version", VERSION_RE)
    target_sequence = validate_version(version)
    expected_publication_sha = require_string(
        plan["signedPublicationSha256"],
        "plan.signedPublicationSha256",
        SHA256_RE,
    )
    publication = regular_file(
        args.signed_publication,
        "signed publication tar",
        max_size=MAX_TAR_TOTAL_BYTES,
    )
    if sha256_file(publication) != expected_publication_sha:
        fail("signed publication tar differs from the approved OSS plan")
    publication_files = read_publication_tar(publication)
    expected_confirmation = CONFIRM_BOOTSTRAP if bootstrap else CONFIRM_OSS
    if args.confirmation != expected_confirmation:
        fail("OSS apply confirmation string differs")
    for name in ("OSS_ACCESS_KEY_ID", "OSS_ACCESS_KEY_SECRET", "OSS_SESSION_TOKEN"):
        if not os.environ.get(name):
            fail(f"short-lived OSS credential environment is incomplete: {name}")
    ossutil = fixed_executable(args.ossutil, args.expected_ossutil_sha256, "ossutil")
    operations = plan["operations"]
    if not isinstance(operations, list) or len(operations) < 2:
        fail("OSS plan operations are missing")
    endpoint = require_oss_endpoint(plan["endpoint"])
    region = require_oss_region(plan["region"])
    bucket = require_bucket(plan["bucket"])
    target_pointer = f"{version}\n".encode()
    if bootstrap:
        if plan["expectedOldPointerBase64"] is not None or plan["expectedOldPointerSha256"] is not None:
            fail("bootstrap plan must bind an absent old pointer")
        expected_old_pointer = None
        expected_old_pointer_sha = None
    else:
        old_base64 = require_string(plan["expectedOldPointerBase64"], "expectedOldPointerBase64")
        old_sha = require_string(plan["expectedOldPointerSha256"], "expectedOldPointerSha256", SHA256_RE)
        try:
            expected_old_pointer = __import__("base64").b64decode(old_base64, validate=True)
        except ValueError:
            fail("expected old pointer base64 is invalid")
        if sha256_bytes(expected_old_pointer) != old_sha:
            fail("expected old pointer digest differs")
        expected_old_pointer_sha = old_sha
    prepared: list[tuple[str | None, bytes, str, str, int, bool]] = []
    object_keys: list[str] = []
    local_names: list[str] = []
    for index, operation_value in enumerate(operations):
        pointer_operation = index == len(operations) - 1
        expected_keys = (
            {"contentBase64", "createOnly", "objectKey", "sha256", "sizeBytes"}
            if pointer_operation
            else {"createOnly", "localName", "objectKey", "sha256", "sizeBytes"}
        )
        operation = require_exact_keys(operation_value, expected_keys, f"operation[{index}]")
        object_key = require_string(operation["objectKey"], f"operation[{index}].objectKey")
        digest = require_string(operation["sha256"], f"operation[{index}].sha256", SHA256_RE)
        size = require_int(operation["sizeBytes"], f"operation[{index}].sizeBytes")
        if type(operation["createOnly"]) is not bool:
            fail("OSS operation createOnly must be a boolean")
        object_keys.append(object_key)
        if pointer_operation:
            if object_key != "channels/candidate/LATEST.txt" or operation["createOnly"] is not bootstrap:
                fail("LATEST operation is not canonical for bootstrap mode")
            try:
                raw = __import__("base64").b64decode(operation["contentBase64"], validate=True)
            except ValueError:
                fail("LATEST content base64 is invalid")
            if raw != target_pointer or len(raw) != size or sha256_bytes(raw) != digest:
                fail("LATEST content/version/digest differs")
            prepared.append((None, raw, object_key, digest, size, operation["createOnly"]))
        else:
            if operation["createOnly"] is not True:
                fail("every immutable version operation must be create-only")
            local_name = require_string(operation["localName"], f"operation[{index}].localName")
            if Path(local_name).name != local_name:
                fail("OSS localName must be one basename")
            local_names.append(local_name)
            if object_key != publication_object_key(version, local_name):
                fail("immutable object key is outside the canonical version namespace")
            raw = publication_files.get(local_name)
            if raw is None or len(raw) != size or sha256_bytes(raw) != digest:
                fail("OSS source object differs from approved plan")
            prepared.append((local_name, raw, object_key, digest, size, True))
    if len(object_keys) != len(set(object_keys)):
        fail("OSS plan contains duplicate object keys")
    artifact_names = [name for name in local_names if ARTIFACT_RE.fullmatch(name)]
    if len(artifact_names) != 1:
        fail("OSS plan must contain one canonical release artifact")
    artifact_match = ARTIFACT_RE.fullmatch(artifact_names[0])
    assert artifact_match is not None
    if artifact_match.group(1) != version:
        fail("OSS plan artifact version differs")
    expected_local_names = SIGNED_PUBLICATION_FIXED_MEMBERS | {
        artifact_names[0],
        f"{artifact_names[0]}.sha256",
    }
    if (
        set(local_names) != expected_local_names
        or set(local_names) != set(publication_files)
        or local_names != sorted(local_names)
    ):
        fail("OSS plan signed-publication object set differs")

    readbacks: list[dict[str, str]] = []
    with tempfile.TemporaryDirectory(prefix="uten-oss-apply-") as temporary:
        temporary_root = Path(temporary)
        environment = minimal_oss_environment(temporary_root)
        upload_root = temporary_root / "publication"
        upload_root.mkdir(mode=0o700)
        pointer_key = "channels/candidate/LATEST.txt"
        observed_pointer = oss_read_object(
            ossutil,
            bucket=bucket,
            object_key=pointer_key,
            endpoint=endpoint,
            region=region,
            environment=environment,
            max_bytes=128,
        )
        pointer_already_final = observed_pointer == target_pointer
        if not pointer_already_final and observed_pointer != expected_old_pointer:
            fail("live LATEST differs from the plan-bound old pointer before upload")

        transition_token = expected_old_pointer_sha or "ABSENT"
        transition_key = (
            f"channels/candidate/transitions/{transition_token}.json"
        )
        transition_raw = canonical_json_bytes(
            {
                "oldPointerSha256": expected_old_pointer_sha,
                "planSha256": expected_plan,
                "product": PRODUCT,
                "schemaVersion": 1,
                "signedPublicationSha256": expected_publication_sha,
                "targetReleaseSequence": target_sequence,
                "targetVersion": version,
            }
        )
        if len(transition_raw) > MAX_OSS_TRANSITION_BYTES:
            fail("OSS transition record exceeds its fixed bound")
        transition_path = temporary_root / "transition.json"
        transition_path.write_bytes(transition_raw)
        existing_transition = oss_read_object(
            ossutil,
            bucket=bucket,
            object_key=transition_key,
            endpoint=endpoint,
            region=region,
            environment=environment,
            max_bytes=MAX_OSS_TRANSITION_BYTES,
        )
        if existing_transition is None:
            try:
                oss_put_object(
                    ossutil,
                    transition_path,
                    bucket=bucket,
                    object_key=transition_key,
                    endpoint=endpoint,
                    region=region,
                    environment=environment,
                    create_only=True,
                )
            except ReleaseError:
                pass
            existing_transition = oss_read_object(
                ossutil,
                bucket=bucket,
                object_key=transition_key,
                endpoint=endpoint,
                region=region,
                environment=environment,
                max_bytes=MAX_OSS_TRANSITION_BYTES,
            )
        if existing_transition != transition_raw:
            fail("old candidate pointer is already claimed by another transition")
        readbacks.append(
            {
                "objectKey": transition_key,
                "sha256": sha256_bytes(transition_raw),
            }
        )

        for local_name, raw, object_key, digest, size, create_only in prepared[:-1]:
            assert local_name is not None and create_only
            local = upload_root / local_name
            local.write_bytes(raw)
            existing = oss_read_object(
                ossutil,
                bucket=bucket,
                object_key=object_key,
                endpoint=endpoint,
                region=region,
                environment=environment,
                max_bytes=size,
            )
            if existing is None:
                try:
                    oss_put_object(
                        ossutil,
                        local,
                        bucket=bucket,
                        object_key=object_key,
                        endpoint=endpoint,
                        region=region,
                        environment=environment,
                        create_only=True,
                    )
                except ReleaseError:
                    # A timeout or create-only race is recoverable only when an
                    # immediate read proves the exact approved bytes now exist.
                    pass
                existing = oss_read_object(
                    ossutil,
                    bucket=bucket,
                    object_key=object_key,
                    endpoint=endpoint,
                    region=region,
                    environment=environment,
                    max_bytes=size,
                )
            if existing != raw or sha256_bytes(existing) != digest:
                fail("immutable OSS object exists with different or unreadable bytes")
            readbacks.append({"objectKey": object_key, "sha256": digest})

        latest_local = temporary_root / "LATEST.txt"
        latest_local.write_bytes(target_pointer)
        live_before_pointer = oss_read_object(
            ossutil,
            bucket=bucket,
            object_key=pointer_key,
            endpoint=endpoint,
            region=region,
            environment=environment,
            max_bytes=128,
        )
        if pointer_already_final:
            if live_before_pointer != target_pointer:
                fail("LATEST changed after exact terminal resume was detected")
        else:
            if live_before_pointer != expected_old_pointer:
                fail("LATEST changed after version uploads and before pointer update")
            try:
                oss_put_object(
                    ossutil,
                    latest_local,
                    bucket=bucket,
                    object_key=pointer_key,
                    endpoint=endpoint,
                    region=region,
                    environment=environment,
                    create_only=bootstrap,
                    no_store=True,
                )
            except ReleaseError:
                # As above, only exact target-pointer bytes can terminalize an
                # ambiguous timeout; every other result remains fail closed.
                pass
            live_before_pointer = oss_read_object(
                ossutil,
                bucket=bucket,
                object_key=pointer_key,
                endpoint=endpoint,
                region=region,
                environment=environment,
                max_bytes=128,
            )
        if live_before_pointer != target_pointer:
            fail("LATEST byte readback differs from approved version")
        readbacks.append(
            {
                "objectKey": pointer_key,
                "sha256": sha256_bytes(target_pointer),
            }
        )
    write_json_exclusive(
        args.output_receipt.resolve(),
        {
            "appliedAtUtc": utc_now(),
            "bootstrap": bootstrap,
            "objects": readbacks,
            "planSha256": expected_plan,
            "product": PRODUCT,
            "schemaVersion": 1,
            "version": version,
        },
    )


def add_network_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--api-url", default=os.environ.get("GITHUB_API_URL", "https://api.github.com"))
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", DEFAULT_REPOSITORY))
    parser.add_argument("--token-env", default="GH_TOKEN")


def add_self_digest(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--expected-self-sha256", required=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    gate = commands.add_parser("github-gate")
    add_network_arguments(gate)
    gate.add_argument("--version", required=True)
    gate.add_argument("--expected-main-sha", required=True)
    gate.add_argument("--confirmation", required=True)
    gate.add_argument("--output", required=True, type=Path)

    artifact = commands.add_parser("verify-github-artifact")
    add_network_arguments(artifact)
    artifact.add_argument("--version", required=True)
    artifact.add_argument("--expected-main-sha", required=True)
    artifact.add_argument("--expected-service-sha256", required=True)
    artifact.add_argument("--artifact-id", required=True, type=int)
    artifact.add_argument("--workflow-run-id", required=True, type=int)
    artifact.add_argument("--workflow-run-attempt", required=True, type=int)
    artifact.add_argument("--require-workflow-success", action="store_true")
    artifact.add_argument("--output-zip", required=True, type=Path)
    artifact.add_argument("--output-evidence", required=True, type=Path)

    candidate = commands.add_parser("verify-candidate")
    add_self_digest(candidate)
    candidate.add_argument("--artifact-zip", required=True, type=Path)
    candidate.add_argument("--evidence", required=True, type=Path)
    candidate.add_argument("--expected-evidence-sha256", required=True)
    candidate.add_argument("--release-guard", required=True, type=Path)
    candidate.add_argument("--expected-release-guard-sha256", required=True)
    candidate.add_argument("--output-receipt", required=True, type=Path)

    tag = commands.add_parser("verify-source-tag")
    add_self_digest(tag)
    tag.add_argument("--git-repository", required=True, type=Path)
    tag.add_argument("--git-bin", required=True, type=Path)
    tag.add_argument("--expected-git-sha256", required=True)
    tag.add_argument("--ssh-keygen", required=True, type=Path)
    tag.add_argument("--expected-ssh-keygen-sha256", required=True)
    tag.add_argument("--allowed-signers", required=True, type=Path)
    tag.add_argument("--expected-allowed-signers-sha256", required=True)
    tag.add_argument("--tag-bundle", required=True, type=Path)
    tag.add_argument("--version", required=True)
    tag.add_argument("--commit", required=True)
    tag.add_argument("--expected-tag-key-id", required=True)
    tag.add_argument("--output-receipt", required=True, type=Path)

    prepare = commands.add_parser("prepare-publication")
    add_self_digest(prepare)
    prepare.add_argument("--artifact-zip", required=True, type=Path)
    prepare.add_argument("--candidate-receipt", required=True, type=Path)
    prepare.add_argument("--tag-receipt", required=True, type=Path)
    prepare.add_argument("--release-key-id", required=True)
    prepare.add_argument("--published-at-utc", required=True)
    prepare.add_argument("--output-dir", required=True, type=Path)

    sign = commands.add_parser("sign-publication")
    add_self_digest(sign)
    sign.add_argument("--publication-dir", required=True, type=Path)
    sign.add_argument("--expected-publication-inputs-sha256", required=True)
    sign.add_argument("--decision", required=True, type=Path)
    sign.add_argument("--decision-validator", required=True, type=Path)
    sign.add_argument("--expected-decision-validator-sha256", required=True)
    sign.add_argument("--private-key", required=True, type=Path)
    sign.add_argument("--ssh-keygen", required=True, type=Path)
    sign.add_argument("--expected-ssh-keygen-sha256", required=True)
    sign.add_argument("--allowed-signers", required=True, type=Path)
    sign.add_argument("--expected-allowed-signers-sha256", required=True)

    verify = commands.add_parser("verify-publication")
    add_self_digest(verify)
    verify.add_argument("--publication-dir", required=True, type=Path)
    verify.add_argument("--allowed-signers", required=True, type=Path)
    verify.add_argument("--expected-allowed-signers-sha256", required=True)
    verify.add_argument("--ssh-keygen", required=True, type=Path)
    verify.add_argument("--expected-ssh-keygen-sha256", required=True)
    verify.add_argument("--release-guard", required=True, type=Path)
    verify.add_argument("--expected-release-guard-sha256", required=True)
    verify.add_argument("--decision-validator", required=True, type=Path)
    verify.add_argument("--expected-decision-validator-sha256", required=True)
    verify.add_argument("--expected-tag-key-id", required=True)
    verify.add_argument("--output-tar", required=True, type=Path)
    verify.add_argument("--output-receipt", required=True, type=Path)

    plan = commands.add_parser("plan-oss-publication")
    add_self_digest(plan)
    plan.add_argument("--signed-publication", required=True, type=Path)
    plan.add_argument("--publication-receipt", required=True, type=Path)
    plan.add_argument("--bucket", required=True)
    plan.add_argument("--endpoint", required=True)
    plan.add_argument("--region", required=True)
    plan.add_argument("--confirmation", required=True)
    plan.add_argument("--current-pointer", type=Path)
    plan.add_argument("--current-channel", type=Path)
    plan.add_argument("--current-channel-signature", type=Path)
    plan.add_argument("--allowed-signers", required=True, type=Path)
    plan.add_argument("--expected-allowed-signers-sha256", required=True)
    plan.add_argument("--ssh-keygen", required=True, type=Path)
    plan.add_argument("--expected-ssh-keygen-sha256", required=True)
    plan.add_argument("--release-guard", required=True, type=Path)
    plan.add_argument("--expected-release-guard-sha256", required=True)
    plan.add_argument("--decision-validator", required=True, type=Path)
    plan.add_argument("--expected-decision-validator-sha256", required=True)
    plan.add_argument("--output-plan", required=True, type=Path)

    apply = commands.add_parser("apply-oss-publication")
    add_self_digest(apply)
    apply.add_argument("--plan", required=True, type=Path)
    apply.add_argument("--expected-plan-sha256", required=True)
    apply.add_argument("--confirmation", required=True)
    apply.add_argument("--signed-publication", required=True, type=Path)
    apply.add_argument("--ossutil", required=True, type=Path)
    apply.add_argument("--expected-ossutil-sha256", required=True)
    apply.add_argument("--output-receipt", required=True, type=Path)
    return parser


COMMANDS = {
    "github-gate": command_github_gate,
    "verify-github-artifact": command_verify_github_artifact,
    "verify-candidate": command_verify_candidate,
    "verify-source-tag": command_verify_source_tag,
    "prepare-publication": command_prepare_publication,
    "sign-publication": command_sign_publication,
    "verify-publication": command_verify_publication,
    "plan-oss-publication": command_plan_oss,
    "apply-oss-publication": command_apply_oss,
}


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        expected_self = getattr(args, "expected_self_sha256", None)
        if expected_self is not None:
            require_string(expected_self, "expected_self_sha256", SHA256_RE)
            self_path = regular_file(
                Path(__file__), "offline_release.py", max_size=MAX_JSON_BYTES
            )
            if sha256_file(self_path) != expected_self:
                fail("offline_release.py digest differs from the pre-reviewed value")
        COMMANDS[args.command](args)
        return 0
    except (ReleaseError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"offline release failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
