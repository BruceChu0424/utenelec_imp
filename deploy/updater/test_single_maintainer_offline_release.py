from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


PROJECT_ROOT = Path(__file__).resolve().parents[2]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


offline_release = load_module(
    "offline_release_tested",
    PROJECT_ROOT / "deploy/release/offline_release.py",
)
decision_validator = load_module(
    "single_maintainer_decision_tested",
    PROJECT_ROOT / "deploy/release/validate_single_maintainer_decision.py",
)


VERSION = "v2026.08.21-1"
COMMIT = "1" * 40
RELEASE_KEY = "SHA256:" + "B" * 43
TAG_KEY = "SHA256:" + "C" * 43


def canonical(value) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def decision_value() -> dict:
    return {
        "activationAuthorized": False,
        "authoritySeparation": {
            "adminKeyAEvidenceRef": None,
            "adminKeyBEvidenceRef": None,
            "gitTagSigningKeyId": TAG_KEY,
            "releaseArtifactSigningKeyId": RELEASE_KEY,
            "serverHostKeyEvidenceRef": None,
        },
        "candidate": {
            "githubEvidenceSha256": "2" * 64,
            "manifestTemplateSha256": "3" * 64,
            "publishCandidateSha256": "4" * 64,
            "verifiedCandidateReceiptSha256": "5" * 64,
        },
        "changeReference": "evidence:CHG-20260821-001",
        "commitSha": COMMIT,
        "decidedAtUtc": "2026-08-21T08:00:00Z",
        "decisionMode": "single-maintainer-offline-exception",
        "environment": "internal-test",
        "independentReviewerPresent": False,
        "maintainerCount": 1,
        "manualActivationRequired": True,
        "ossPublicationAuthorized": False,
        "publication": {
            "channelSha256": "6" * 64,
            "manifestSha256": "7" * 64,
            "sourceTagBundleSha256": "8" * 64,
            "sourceTagObjectSha": "9" * 40,
            "updaterWheelhouseAttestationSha256": "a" * 64,
        },
        "remoteTagPublished": False,
        "residualRisks": list(decision_validator.REQUIRED_RISKS),
        "schemaVersion": 1,
        "singleMaintainerException": True,
        "sourceRef": f"refs/tags/{VERSION}",
        "stagingAuthorized": False,
        "targetHostAuthority": {
            "evidenceReference": None,
            "h01ToH12Complete": False,
            "projectKnownHostsComplete": False,
        },
        "version": VERSION,
    }


class DecisionValidatorTest(unittest.TestCase):
    def write(self, root: Path, value: dict, *, canonical_bytes: bool = True) -> Path:
        path = root / "decision.json"
        path.write_bytes(canonical(value) if canonical_bytes else json.dumps(value).encode())
        return path

    def test_valid_decision_is_canonical_and_binds_independent_values(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write(Path(temporary), decision_value())
            value, raw = decision_validator.load_canonical_json(path)
            summary = decision_validator.validate_decision(
                value,
                expected_version=VERSION,
                expected_commit=COMMIT,
                expected_manifest_sha256="7" * 64,
                expected_channel_sha256="6" * 64,
                expected_candidate_receipt_sha256="5" * 64,
                expected_github_evidence_sha256="2" * 64,
                expected_manifest_template_sha256="3" * 64,
                expected_publish_candidate_sha256="4" * 64,
                expected_source_tag_bundle_sha256="8" * 64,
                expected_source_tag_object_sha="9" * 40,
                expected_updater_attestation_sha256="a" * 64,
                expected_release_key_id=RELEASE_KEY,
                expected_tag_key_id=TAG_KEY,
            )
            self.assertEqual(summary["version"], VERSION)
            self.assertEqual(hashlib.sha256(raw).hexdigest(), hashlib.sha256(path.read_bytes()).hexdigest())

    def test_noncanonical_duplicate_and_extra_json_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            value = decision_value()
            with self.assertRaisesRegex(decision_validator.DecisionError, "not canonical"):
                decision_validator.load_canonical_json(self.write(root, value, canonical_bytes=False))
            duplicate = canonical(value).decode().replace(
                f'  "version": "{VERSION}"\n}}',
                f'  "version": "{VERSION}",\n  "version": "{VERSION}"\n}}',
            )
            (root / "duplicate.json").write_text(duplicate, encoding="utf-8")
            with self.assertRaises(decision_validator.DecisionError):
                decision_validator.load_canonical_json(root / "duplicate.json")
            value["extra"] = True
            with self.assertRaisesRegex(decision_validator.DecisionError, "key"):
                decision_validator.validate_decision(value)
            nonfinite = decision_value()
            nonfinite["maintainerCount"] = float("nan")
            (root / "nonfinite.json").write_bytes(canonical(nonfinite))
            with self.assertRaisesRegex(decision_validator.DecisionError, "non-finite"):
                decision_validator.load_canonical_json(root / "nonfinite.json")

    def test_authorization_escalation_and_authority_reuse_are_rejected(self) -> None:
        for field in ("activationAuthorized", "stagingAuthorized", "ossPublicationAuthorized", "remoteTagPublished"):
            value = decision_value()
            value[field] = True
            with self.assertRaises(decision_validator.DecisionError, msg=field):
                decision_validator.validate_decision(value)
        same_key = decision_value()
        same_key["authoritySeparation"]["gitTagSigningKeyId"] = RELEASE_KEY
        with self.assertRaisesRegex(decision_validator.DecisionError, "different"):
            decision_validator.validate_decision(same_key)

    def test_incomplete_host_authority_cannot_claim_evidence(self) -> None:
        value = decision_value()
        value["targetHostAuthority"]["evidenceReference"] = "evidence:fake"
        with self.assertRaisesRegex(decision_validator.DecisionError, "incomplete"):
            decision_validator.validate_decision(value)

    def test_complete_host_authority_requires_four_distinct_evidence_refs(self) -> None:
        value = decision_value()
        value["authoritySeparation"].update(
            {
                "adminKeyAEvidenceRef": "evidence:admin-a",
                "adminKeyBEvidenceRef": "evidence:admin-b",
                "serverHostKeyEvidenceRef": "evidence:host-key",
            }
        )
        value["targetHostAuthority"].update(
            {
                "evidenceReference": "evidence:h01-h12-and-known-hosts",
                "h01ToH12Complete": True,
                "projectKnownHostsComplete": True,
            }
        )
        decision_validator.validate_decision(value)
        missing = json.loads(json.dumps(value))
        missing["authoritySeparation"]["adminKeyBEvidenceRef"] = None
        with self.assertRaisesRegex(decision_validator.DecisionError, "requires"):
            decision_validator.validate_decision(missing)
        duplicate = json.loads(json.dumps(value))
        duplicate["authoritySeparation"]["adminKeyBEvidenceRef"] = "evidence:admin-a"
        with self.assertRaisesRegex(decision_validator.DecisionError, "distinct"):
            decision_validator.validate_decision(duplicate)

    def test_repository_example_is_never_accepted_as_a_real_decision(self) -> None:
        example = PROJECT_ROOT / "deploy/release/single-maintainer-release-decision.example.json"
        value, _ = decision_validator.load_canonical_json(example)
        with self.assertRaises(decision_validator.DecisionError):
            decision_validator.validate_decision(value)


def build_candidate(
    *,
    extra: tuple[str, bytes] | None = None,
    link: bool = False,
    standalone_backend_differs: bool = False,
) -> tuple[bytes, bytes]:
    artifact_name = f"uten-imp-{VERSION}-{COMMIT[:12]}.tar.gz"
    backend = b'{"component":"backend"}\n'
    flutter = b'{"component":"flutter"}\n'
    attestation = canonical({"schemaVersion": 1})
    artifact_io = io.BytesIO()
    with tarfile.open(fileobj=artifact_io, mode="w:gz") as release:
        for name, raw in (
            (f"{VERSION}/sbom/backend.cdx.json", backend),
            (f"{VERSION}/sbom/flutter.cdx.json", flutter),
            (
                f"{VERSION}/sbom/updater/updater-wheelhouse.attestation.json",
                attestation,
            ),
        ):
            info = tarfile.TarInfo(name)
            info.size = len(raw)
            release.addfile(info, io.BytesIO(raw))
    artifact = artifact_io.getvalue()
    files = {
        artifact_name: artifact,
        f"{artifact_name}.sha256": f"{hashlib.sha256(artifact).hexdigest()}  {artifact_name}\n".encode(),
        "backend.cdx.json": (
            b'{"component":"tampered"}\n'
            if standalone_backend_differs
            else backend
        ),
        "flutter.cdx.json": flutter,
        "manifest.template.json": canonical(
            {
                "commitSha": COMMIT,
                "signingKeyId": offline_release.PLACEHOLDER_KEY_ID,
                "sourceRef": f"refs/tags/{VERSION}",
                "version": VERSION,
            }
        ),
        "updater-wheelhouse.attestation.json": attestation,
    }
    inventory = "".join(
        f"{hashlib.sha256(raw).hexdigest()}  {name}\n" for name, raw in files.items()
    ).encode()
    files = {"PUBLISH_SHA256SUMS": inventory, **files}
    if extra is not None:
        files[extra[0]] = extra[1]
    candidate_io = io.BytesIO()
    with tarfile.open(fileobj=candidate_io, mode="w:") as archive:
        for name, raw in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(raw)
            if link and name == "backend.cdx.json":
                info.type = tarfile.SYMTYPE
                info.linkname = "manifest.template.json"
                info.size = 0
            archive.addfile(info, None if info.issym() else io.BytesIO(raw))
    candidate = candidate_io.getvalue()
    zip_io = io.BytesIO()
    with zipfile.ZipFile(zip_io, mode="w", compression=zipfile.ZIP_STORED) as archive:
        archive.writestr("publish-candidate.tar", candidate)
    return candidate, zip_io.getvalue()


class CandidateArchiveTest(unittest.TestCase):
    def test_exact_candidate_zip_and_tar_are_verified_without_execution(self) -> None:
        candidate, artifact_zip = build_candidate()
        extracted, digest = offline_release.candidate_tar_from_zip(artifact_zip)
        self.assertEqual(extracted, candidate)
        self.assertEqual(digest, hashlib.sha256(candidate).hexdigest())
        info = offline_release.verify_candidate_tar(candidate)
        self.assertEqual(info["version"], VERSION)
        self.assertEqual(info["commitSha"], COMMIT)
        offline_release.verify_candidate_payload_copies(info)

    def test_standalone_metadata_must_equal_release_archive_payload(self) -> None:
        candidate, artifact_zip = build_candidate(standalone_backend_differs=True)
        info = offline_release.verify_candidate_tar(candidate)
        with self.assertRaisesRegex(offline_release.ReleaseError, "differs"):
            offline_release.verify_candidate_payload_copies(info)
        with tempfile.TemporaryDirectory() as temporary:
            candidate_zip = Path(temporary) / "tampered-candidate.zip"
            candidate_zip.write_bytes(artifact_zip)
            with self.assertRaisesRegex(offline_release.ReleaseError, "differs"):
                offline_release.command_prepare_publication(
                    argparse.Namespace(artifact_zip=candidate_zip)
                )

    def test_zip_extra_member_and_tar_extra_or_link_fail_closed(self) -> None:
        _candidate, artifact_zip = build_candidate()
        value = io.BytesIO(artifact_zip)
        with zipfile.ZipFile(value, mode="a") as archive:
            archive.writestr("extra", b"x")
        with self.assertRaisesRegex(offline_release.ReleaseError, "only"):
            offline_release.candidate_tar_from_zip(value.getvalue())
        extra_candidate, _ = build_candidate(extra=("extra", b"x"))
        with self.assertRaises(offline_release.ReleaseError):
            offline_release.verify_candidate_tar(extra_candidate)
        linked_candidate, _ = build_candidate(link=True)
        with self.assertRaisesRegex(offline_release.ReleaseError, "non-regular"):
            offline_release.verify_candidate_tar(linked_candidate)

    def test_high_ratio_zip_bomb_is_rejected_before_member_read(self) -> None:
        value = io.BytesIO()
        with zipfile.ZipFile(value, mode="w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("publish-candidate.tar", b"0" * (8 * 1024 * 1024))
        with self.assertRaisesRegex(offline_release.ReleaseError, "compression ratio"):
            offline_release.candidate_tar_from_zip(value.getvalue())

    def test_tar_traversal_and_duplicate_inventory_are_rejected(self) -> None:
        candidate, _ = build_candidate()
        files = offline_release.verify_candidate_tar(candidate)["candidateFiles"]
        bad = io.BytesIO()
        with tarfile.open(fileobj=bad, mode="w:") as archive:
            info = tarfile.TarInfo("../escape")
            info.size = 1
            archive.addfile(info, io.BytesIO(b"x"))
        with self.assertRaises(offline_release.ReleaseError):
            offline_release.verify_candidate_tar(bad.getvalue())
        inventory = files["PUBLISH_SHA256SUMS"] + files["PUBLISH_SHA256SUMS"].splitlines()[0] + b"\n"
        with self.assertRaisesRegex(offline_release.ReleaseError, "duplicate"):
            offline_release.parse_sha256_inventory(inventory, set())

    def test_offline_candidate_requires_oob_evidence_and_completed_workflow(self) -> None:
        candidate, artifact_zip = build_candidate()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            zip_path = root / "candidate.zip"
            zip_path.write_bytes(artifact_zip)
            evidence_value = {
                "artifact": {
                    "serviceSha256": hashlib.sha256(artifact_zip).hexdigest(),
                    "sizeBytes": len(artifact_zip),
                    "zipMemberSha256": hashlib.sha256(candidate).hexdigest(),
                },
                "product": "uten-imp",
                "schemaVersion": 1,
                "source": {"expectedMainSha": COMMIT, "version": VERSION},
                "workflow": {
                    "conclusion": "success",
                    "path": ".github/workflows/unsigned-release-candidate.yml",
                    "runAttempt": 1,
                    "status": "completed",
                },
            }
            evidence = root / "evidence.json"
            evidence.write_bytes(canonical(evidence_value))
            output = root / "receipt.json"
            with mock.patch.object(offline_release, "run_tool") as run_tool:
                offline_release.command_verify_candidate(
                    argparse.Namespace(
                        evidence=evidence,
                        expected_evidence_sha256=hashlib.sha256(evidence.read_bytes()).hexdigest(),
                        artifact_zip=zip_path,
                        release_guard=Path("release_guard.py"),
                        expected_release_guard_sha256="1" * 64,
                        output_receipt=output,
                    )
                )
            self.assertEqual(run_tool.call_count, 2)
            receipt, _ = offline_release.load_json(output, "candidate receipt")
            self.assertEqual(receipt["publishCandidateSha256"], hashlib.sha256(candidate).hexdigest())
            forged = dict(evidence_value)
            forged["workflow"] = dict(evidence_value["workflow"], status="in_progress", conclusion=None)
            evidence.write_bytes(canonical(forged))
            with self.assertRaisesRegex(offline_release.ReleaseError, "successful"):
                offline_release.command_verify_candidate(
                    argparse.Namespace(
                        evidence=evidence,
                        expected_evidence_sha256=hashlib.sha256(evidence.read_bytes()).hexdigest(),
                        artifact_zip=zip_path,
                        release_guard=Path("release_guard.py"),
                        expected_release_guard_sha256="1" * 64,
                        output_receipt=root / "must-not-exist.json",
                    )
                )


class FakeGitHubClient:
    def __init__(self) -> None:
        self.repository = offline_release.DEFAULT_REPOSITORY
        self.runs: dict[str, list[dict]] = {}
        self.jobs: dict[int, list[dict]] = {}
        self.checks: dict[str, dict] = {}

    def pages(self, path: str, key: str) -> list[dict]:
        if key == "workflow_runs":
            for workflow_path, values in self.runs.items():
                if urllib_quote(Path(workflow_path).name) in path:
                    return values
            return []
        match = re.search(r"/runs/([0-9]+)/attempts/([0-9]+)/jobs", path)
        if key != "jobs" or match is None:
            raise AssertionError(path)
        return self.jobs[int(match.group(1))]

    def json(self, url: str):
        return self.checks[url], {}, 200


def urllib_quote(value: str) -> str:
    import urllib.parse

    return urllib.parse.quote(value, safe="")


def ci_fixture() -> FakeGitHubClient:
    client = FakeGitHubClient()
    next_id = 100
    for workflow_path, names in offline_release.WORKFLOW_JOBS.items():
        run_id = next_id
        next_id += 100
        client.runs[workflow_path] = [
            {
                "check_suite_id": run_id + 1,
                "conclusion": "success",
                "event": "push",
                "head_branch": "main",
                "head_sha": COMMIT,
                "id": run_id,
                "path": workflow_path,
                "run_attempt": 1,
                "status": "completed",
            }
        ]
        jobs = []
        for offset, name in enumerate(sorted(names), start=1):
            check_url = f"https://api.github.test/checks/{run_id + offset}"
            jobs.append(
                {
                    "check_run_url": check_url,
                    "conclusion": "success",
                    "head_sha": COMMIT,
                    "id": run_id + offset,
                    "name": name,
                    "run_attempt": 1,
                    "status": "completed",
                }
            )
            client.checks[check_url] = {
                "app": {"slug": "github-actions"},
                "conclusion": "success",
                "head_sha": COMMIT,
                "id": run_id + 1000 + offset,
                "name": name,
                "status": "completed",
            }
        client.jobs[run_id] = jobs
    return client


class MainCiEvidenceTest(unittest.TestCase):
    def test_exact_three_workflows_and_seven_jobs_are_accepted(self) -> None:
        evidence = offline_release.collect_main_ci(ci_fixture(), COMMIT)
        self.assertEqual(len(evidence), 3)
        self.assertEqual(sum(len(run["jobs"]) for run in evidence), 7)
        self.assertEqual(
            {job["name"] for run in evidence for job in run["jobs"]},
            set().union(*offline_release.WORKFLOW_JOBS.values()),
        )

    def test_duplicate_extra_old_attempt_and_wrong_app_fail_closed(self) -> None:
        duplicate = ci_fixture()
        first_path = next(iter(duplicate.runs))
        duplicate.runs[first_path].append(dict(duplicate.runs[first_path][0]))
        with self.assertRaisesRegex(offline_release.ReleaseError, "exactly one"):
            offline_release.collect_main_ci(duplicate, COMMIT)

        extra = ci_fixture()
        first_run = next(iter(extra.jobs))
        extra.jobs[first_run].append(dict(extra.jobs[first_run][0], id=9999, name="extra"))
        with self.assertRaisesRegex(offline_release.ReleaseError, "job set"):
            offline_release.collect_main_ci(extra, COMMIT)

        old = ci_fixture()
        first_job = next(iter(old.jobs.values()))[0]
        first_job["run_attempt"] = 0
        with self.assertRaisesRegex(offline_release.ReleaseError, "run_attempt|positive"):
            offline_release.collect_main_ci(old, COMMIT)

        rerun = ci_fixture()
        next(iter(rerun.runs.values()))[0]["run_attempt"] = 2
        with self.assertRaisesRegex(offline_release.ReleaseError, "run_attempt"):
            offline_release.collect_main_ci(rerun, COMMIT)

        missing = ci_fixture()
        del next(iter(missing.jobs.values()))[0]["run_attempt"]
        with self.assertRaisesRegex(offline_release.ReleaseError, "positive integer"):
            offline_release.collect_main_ci(missing, COMMIT)

        app = ci_fixture()
        app.checks[next(iter(app.checks))]["app"]["slug"] = "third-party"
        with self.assertRaisesRegex(offline_release.ReleaseError, "github-actions"):
            offline_release.collect_main_ci(app, COMMIT)

    def test_unsigned_artifact_run_requires_exact_workflow_dispatch_lineage(self) -> None:
        run = {
            "conclusion": "success",
            "event": "workflow_dispatch",
            "head_branch": "main",
            "head_sha": COMMIT,
            "id": 77,
            "path": ".github/workflows/unsigned-release-candidate.yml",
            "run_attempt": 1,
            "status": "completed",
        }
        self.assertEqual(
            offline_release.validate_unsigned_workflow_run(
                run,
                run_id=77,
                run_attempt=1,
                commit=COMMIT,
                require_success=True,
            ),
            ("completed", "success"),
        )
        for key, value in (
            ("path", ".github/workflows/other.yml"),
            ("event", "push"),
            ("head_branch", "feature"),
            ("head_sha", "2" * 40),
            ("run_attempt", 2),
        ):
            forged = dict(run)
            forged[key] = value
            with self.assertRaisesRegex(offline_release.ReleaseError, "lineage"):
                offline_release.validate_unsigned_workflow_run(
                    forged,
                    run_id=77,
                    run_attempt=1,
                    commit=COMMIT,
                    require_success=True,
                )
        incomplete = dict(run, status="in_progress", conclusion=None)
        with self.assertRaisesRegex(offline_release.ReleaseError, "completed"):
            offline_release.validate_unsigned_workflow_run(
                incomplete,
                run_id=77,
                run_attempt=1,
                commit=COMMIT,
                require_success=True,
            )


class SourceTagIsolationTest(unittest.TestCase):
    def test_repo_local_git_config_cannot_override_fixed_tag_verifier(self) -> None:
        if os.name == "nt":
            self.skipTest("real SSH-signed Git tag isolation runs on Linux")
        git_name = shutil.which("git")
        ssh_name = shutil.which("ssh-keygen")
        if git_name is None or ssh_name is None:
            self.skipTest("git/ssh-keygen are unavailable")
        git = Path(git_name)
        ssh_keygen = Path(ssh_name)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository = root / "repository"
            subprocess.run([str(git), "init", str(repository)], check=True, capture_output=True)
            subprocess.run([str(git), "-C", str(repository), "config", "user.name", "Tagger"], check=True)
            subprocess.run([str(git), "-C", str(repository), "config", "user.email", "tagger@example.test"], check=True)
            (repository / "source.txt").write_text("reviewed\n", encoding="utf-8")
            subprocess.run([str(git), "-C", str(repository), "add", "source.txt"], check=True)
            subprocess.run([str(git), "-C", str(repository), "commit", "-m", "source"], check=True, capture_output=True)
            key = root / "tag-key"
            subprocess.run([str(ssh_keygen), "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
            subprocess.run(
                [str(git), "-C", str(repository), "-c", "gpg.format=ssh", "-c", f"user.signingkey={key}", "tag", "-s", VERSION, "-m", "reviewed tag"],
                check=True,
                capture_output=True,
            )
            commit = subprocess.run(
                [str(git), "-C", str(repository), "rev-parse", "HEAD"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            bundle = root / "source-tag.bundle"
            subprocess.run([str(git), "-C", str(repository), "bundle", "create", str(bundle), f"refs/tags/{VERSION}"], check=True)
            public = Path(str(key) + ".pub").read_text(encoding="utf-8").strip()
            allowed = root / "tag-allowed-signers"
            allowed.write_text(f"tagger@example.test {public}\n", encoding="utf-8")
            fingerprint = subprocess.run(
                [str(ssh_keygen), "-E", "sha256", "-lf", str(key) + ".pub"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.split()[1]
            evil = root / "evil-allowed-signers"
            evil.write_text("attacker ssh-ed25519 INVALID\n", encoding="utf-8")
            subprocess.run([str(git), "-C", str(repository), "config", "gpg.ssh.program", "/bin/false"], check=True)
            subprocess.run([str(git), "-C", str(repository), "config", "gpg.ssh.allowedSignersFile", str(evil)], check=True)
            subprocess.run([str(git), "-C", str(repository), "config", "core.fsmonitor", "/bin/false"], check=True)
            receipt = root / "tag-receipt.json"
            offline_release.command_verify_source_tag(
                argparse.Namespace(
                    version=VERSION,
                    commit=commit,
                    expected_tag_key_id=fingerprint,
                    git_repository=repository,
                    git_bin=git,
                    expected_git_sha256=hashlib.sha256(git.read_bytes()).hexdigest(),
                    ssh_keygen=ssh_keygen,
                    expected_ssh_keygen_sha256=hashlib.sha256(ssh_keygen.read_bytes()).hexdigest(),
                    allowed_signers=allowed,
                    expected_allowed_signers_sha256=hashlib.sha256(allowed.read_bytes()).hexdigest(),
                    tag_bundle=bundle,
                    output_receipt=receipt,
                )
            )
            value, _ = offline_release.load_json(receipt, "tag receipt")
            self.assertEqual(value["tagObjectSha"], subprocess.run([str(git), "-C", str(repository), "rev-parse", f"refs/tags/{VERSION}"], check=True, capture_output=True, text=True).stdout.strip())
            self.assertEqual(value["gitTagSigningKeyId"], fingerprint)
            thin_bundle = root / "thin-source-tag.bundle"
            subprocess.run(
                [
                    str(git),
                    "-C",
                    str(repository),
                    "bundle",
                    "create",
                    str(thin_bundle),
                    f"refs/tags/{VERSION}",
                    "^HEAD",
                ],
                check=True,
                capture_output=True,
            )
            with self.assertRaisesRegex(
                offline_release.ReleaseError, "fixed external command failed"
            ):
                offline_release.command_verify_source_tag(
                    argparse.Namespace(
                        version=VERSION,
                        commit=commit,
                        expected_tag_key_id=fingerprint,
                        git_repository=repository,
                        git_bin=git,
                        expected_git_sha256=hashlib.sha256(git.read_bytes()).hexdigest(),
                        ssh_keygen=ssh_keygen,
                        expected_ssh_keygen_sha256=hashlib.sha256(ssh_keygen.read_bytes()).hexdigest(),
                        allowed_signers=allowed,
                        expected_allowed_signers_sha256=hashlib.sha256(allowed.read_bytes()).hexdigest(),
                        tag_bundle=thin_bundle,
                        output_receipt=root / "thin-must-not-pass.json",
                    )
                )


class ReleaseSignatureBindingTest(unittest.TestCase):
    def test_four_namespace_verifier_selects_only_expected_release_key(self) -> None:
        if os.name == "nt":
            self.skipTest("real ssh-keygen signature binding runs on Linux")
        ssh_name = shutil.which("ssh-keygen")
        if ssh_name is None:
            self.skipTest("ssh-keygen is unavailable")
        ssh_keygen = Path(ssh_name)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            key = root / "release-key"
            subprocess.run([str(ssh_keygen), "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
            public_fields = Path(str(key) + ".pub").read_text(encoding="utf-8").split()[:2]
            allowed = root / "allowed_signers"
            allowed.write_text(
                f"{offline_release.SIGNER_IDENTITY} {public_fields[0]} {public_fields[1]}\n",
                encoding="utf-8",
            )
            fingerprint = subprocess.run(
                [str(ssh_keygen), "-E", "sha256", "-lf", str(key) + ".pub"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.split()[1]
            source = root / "decision.json"
            source.write_bytes(canonical(decision_value()))
            signature = root / "decision.sig"
            offline_release._ssh_sign(
                ssh_keygen,
                key,
                offline_release.DECISION_NAMESPACE,
                source,
                signature,
            )
            offline_release._ssh_verify(
                ssh_keygen,
                allowed,
                offline_release.DECISION_NAMESPACE,
                source,
                signature,
                fingerprint,
            )
            source.write_bytes(source.read_bytes() + b" ")
            with self.assertRaises(offline_release.ReleaseError):
                offline_release._ssh_verify(
                    ssh_keygen,
                    allowed,
                    offline_release.DECISION_NAMESPACE,
                    source,
                    signature,
                    fingerprint,
                )


class WorkflowContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.entry = (PROJECT_ROOT / ".github/workflows/unsigned-release-candidate.yml").read_text(encoding="utf-8")
        self.build = (PROJECT_ROOT / ".github/workflows/_unsigned-candidate-build.yml").read_text(encoding="utf-8")

    def test_entry_is_dispatch_only_and_permissions_are_read_only(self) -> None:
        trigger = self.entry[self.entry.index("on:") : self.entry.index("permissions:")]
        self.assertIn("workflow_dispatch:", trigger)
        self.assertNotIn("push:", trigger)
        self.assertNotIn("pull_request:", trigger)
        self.assertIn("actions: read", self.entry)
        self.assertIn("checks: read", self.entry)
        self.assertIn("contents: read", self.entry)
        self.assertIn("GITHUB_REF", self.entry)
        self.assertIn("refs/heads/main", self.entry)
        self.assertIn("persist-credentials: false", self.entry)

    def test_reusable_builder_is_call_only_and_preserves_unsigned_contract(self) -> None:
        trigger = self.build[self.build.index("on:") : self.build.index("permissions:")]
        self.assertIn("workflow_call:", trigger)
        self.assertNotIn("workflow_dispatch:", trigger)
        self.assertIn('--source-ref "refs/tags/$version"', self.build)
        self.assertIn("PUBLISH_SHA256SUMS", self.build)
        self.assertIn("updater-wheelhouse.attestation.json", self.build)
        self.assertIn("retention-days: 1", self.build)
        self.assertIn("compression-level: 0", self.build)
        self.assertIn("268435456", self.build)
        self.assertIn("overwrite: false", self.build)
        self.assertNotIn(".github/workflows/release.yml", self.entry + self.build)

    def test_workflows_have_no_secret_environment_oidc_or_publish_capability(self) -> None:
        combined = self.entry + self.build
        for forbidden in (
            "${{ secrets.",
            "id-token:",
            "environment:",
            "ALIYUN_OSS_",
            "ossutil",
            "ssh-keygen -Y sign",
            "systemctl",
        ):
            self.assertNotIn(forbidden, combined.lower() if forbidden.islower() else combined)
        self.assertNotIn("publish-release", combined)
        self.assertNotIn("bootstrap-initial-candidate", combined)

    def test_all_actions_are_pinned_to_full_commit_sha(self) -> None:
        references = re.findall(r"^\s*- uses: ([^@\s]+)@([^\s]+)", self.entry + self.build, re.MULTILINE)
        self.assertGreaterEqual(len(references), 5)
        for action, reference in references:
            if action.startswith("./"):
                continue
            self.assertRegex(reference, r"^[0-9a-f]{40}$", action)

    def test_python_sources_parse_and_candidate_is_never_executed(self) -> None:
        import ast

        source = (PROJECT_ROOT / "deploy/release/offline_release.py").read_text(encoding="utf-8")
        ast.parse(source)
        ast.parse((PROJECT_ROOT / "deploy/release/validate_single_maintainer_decision.py").read_text(encoding="utf-8"))
        self.assertNotIn("exec(", source)
        self.assertNotIn("importlib", source)
        self.assertIn("sys.executable, \"-I\"", source)

    def test_every_workflow_shell_block_and_inline_python_parse(self) -> None:
        bash = shutil.which("bash")
        if bash is None or os.name == "nt":
            self.skipTest("workflow bash syntax gate runs on Linux")
        for workflow in (self.entry, self.build):
            lines = workflow.splitlines()
            blocks: list[str] = []
            index = 0
            while index < len(lines):
                if lines[index].startswith("        run: |"):
                    index += 1
                    body: list[str] = []
                    while index < len(lines):
                        line = lines[index]
                        if line and len(line) - len(line.lstrip()) <= 8:
                            break
                        body.append(line[10:] if line.startswith("          ") else "")
                        index += 1
                    blocks.append("\n".join(body) + "\n")
                    continue
                index += 1
            self.assertTrue(blocks)
            for block in blocks:
                self.assertNotIn(
                    "${{",
                    block,
                    "GitHub expressions must enter shell only through env",
                )
                completed = subprocess.run(
                    [bash, "-n"], input=block, text=True, capture_output=True, check=False
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
        import ast

        marker = "          python3 - <<'PY'\n"
        start = self.build.index(marker) + len(marker)
        end = self.build.index("\n          PY", start)
        inline = "\n".join(
            line[10:] if line.startswith("          ") else line
            for line in self.build[start:end].splitlines()
        )
        ast.parse(inline)


def signed_publication_fixture(root: Path) -> tuple[Path, Path]:
    artifact_name = f"uten-imp-{VERSION}-{COMMIT[:12]}.tar.gz"
    artifact_raw = b"artifact"
    backend_raw = b'{"bomFormat":"CycloneDX","component":"backend"}\n'
    flutter_raw = b'{"bomFormat":"CycloneDX","component":"flutter"}\n'
    attestation_raw = b'{"schemaVersion":1}\n'
    manifest_raw = canonical(
        {
            "artifact": {
                "fileName": artifact_name,
                "objectKey": f"releases/{VERSION}/{artifact_name}",
                "sha256": hashlib.sha256(artifact_raw).hexdigest(),
                "sizeBytes": len(artifact_raw),
            },
            "commitSha": COMMIT,
            "sbom": {
                "backend": {
                    "path": "sbom/backend.cdx.json",
                    "sha256": hashlib.sha256(backend_raw).hexdigest(),
                },
                "flutter": {
                    "path": "sbom/flutter.cdx.json",
                    "sha256": hashlib.sha256(flutter_raw).hexdigest(),
                },
                "format": "CycloneDX",
            },
            "signingKeyId": RELEASE_KEY,
            "sourceRef": f"refs/tags/{VERSION}",
            "version": VERSION,
        }
    )
    channel_raw = canonical(
        {
            "channel": "candidate",
            "commitSha": COMMIT,
            "manifest": {
                "objectKey": f"releases/{VERSION}/manifest.json",
                "sha256": hashlib.sha256(manifest_raw).hexdigest(),
                "signatureObjectKey": f"releases/{VERSION}/manifest.sig",
            },
            "product": "uten-imp",
            "publishedAtUtc": "2026-08-21T08:00:00Z",
            "releaseSequence": offline_release.validate_version(VERSION),
            "schemaVersion": 1,
            "signingKeyId": RELEASE_KEY,
            "version": VERSION,
        }
    )
    decision = decision_value()
    decision["publication"]["manifestSha256"] = hashlib.sha256(manifest_raw).hexdigest()
    decision["publication"]["channelSha256"] = hashlib.sha256(channel_raw).hexdigest()
    files = {
        artifact_name: artifact_raw,
        f"{artifact_name}.sha256": (
            f"{hashlib.sha256(artifact_raw).hexdigest()}  {artifact_name}\n".encode()
        ),
        "backend.cdx.json": backend_raw,
        "channel.json": channel_raw,
        "channel.sig": b"signature",
        "flutter.cdx.json": flutter_raw,
        "manifest.json": manifest_raw,
        "manifest.sig": b"signature",
        "release-decision.json": canonical(decision),
        "release-decision.sig": b"signature",
        "updater-wheelhouse.attestation.json": attestation_raw,
        "updater-wheelhouse.attestation.sig": b"signature",
    }
    files["SIGNED_SHA256SUMS"] = "".join(
        f"{hashlib.sha256(raw).hexdigest()}  {name}\n" for name, raw in sorted(files.items())
    ).encode()
    publication = root / "signed-publication.tar"
    with tarfile.open(publication, "w:") as archive:
        for name, raw in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(raw)
            archive.addfile(info, io.BytesIO(raw))
    receipt = root / "publication-receipt.json"
    receipt.write_bytes(
        canonical(
            {
                "allowedSignersSha256": "d" * 64,
                "candidateReceiptSha256": "5" * 64,
                "channelSha256": hashlib.sha256(channel_raw).hexdigest(),
                "commitSha": COMMIT,
                "decisionSha256": hashlib.sha256(canonical(decision)).hexdigest(),
                "gitTagSigningKeyId": TAG_KEY,
                "githubEvidenceSha256": "2" * 64,
                "manifestTemplateSha256": "3" * 64,
                "manifestSha256": hashlib.sha256(manifest_raw).hexdigest(),
                "product": "uten-imp",
                "publishCandidateSha256": "4" * 64,
                "releaseArtifactSigningKeyId": RELEASE_KEY,
                "schemaVersion": 1,
                "signedPublicationSha256": hashlib.sha256(publication.read_bytes()).hexdigest(),
                "sourceTagBundleSha256": "8" * 64,
                "sourceTagObjectSha": "9" * 40,
                "updaterWheelhouseAttestationSha256": hashlib.sha256(
                    attestation_raw
                ).hexdigest(),
                "version": VERSION,
            }
        )
    )
    return publication, receipt


def rewrite_signed_publication(
    original: Path, output: Path, replacements: dict[str, bytes]
) -> Path:
    files = offline_release.read_publication_tar(original)
    files.update(replacements)
    files["SIGNED_SHA256SUMS"] = "".join(
        f"{hashlib.sha256(raw).hexdigest()}  {name}\n"
        for name, raw in sorted(files.items())
        if name != "SIGNED_SHA256SUMS"
    ).encode()
    with tarfile.open(output, "w:") as archive:
        for name, raw in sorted(files.items()):
            info = tarfile.TarInfo(name)
            info.size = len(raw)
            archive.addfile(info, io.BytesIO(raw))
    return output


def oss_apply_fixture(root: Path) -> tuple[Path, Path, dict[str, bytes]]:
    publication, _receipt = signed_publication_fixture(root)
    files = offline_release.read_publication_tar(publication)
    operations = []
    for name in sorted(files):
        operations.append(
            {
                "createOnly": True,
                "localName": name,
                "objectKey": offline_release.publication_object_key(VERSION, name),
                "sha256": hashlib.sha256(files[name]).hexdigest(),
                "sizeBytes": len(files[name]),
            }
        )
    pointer = f"{VERSION}\n".encode()
    operations.append(
        {
            "contentBase64": __import__("base64").b64encode(pointer).decode(),
            "createOnly": True,
            "objectKey": "channels/candidate/LATEST.txt",
            "sha256": hashlib.sha256(pointer).hexdigest(),
            "sizeBytes": len(pointer),
        }
    )
    plan_value = {
        "bootstrap": True,
        "bucket": "uten-test",
        "endpoint": "https://oss.example.invalid",
        "expectedOldPointerBase64": None,
        "expectedOldPointerSha256": None,
        "operations": operations,
        "product": "uten-imp",
        "region": "cn-test-1",
        "schemaVersion": 1,
        "signedPublicationSha256": hashlib.sha256(publication.read_bytes()).hexdigest(),
        "version": VERSION,
    }
    plan = root / "oss-apply-plan.json"
    plan.write_bytes(canonical(plan_value))
    return publication, plan, files


def expected_transition(plan: Path) -> tuple[str, bytes]:
    value, raw = offline_release.load_json(plan, "OSS plan")
    old_sha = value["expectedOldPointerSha256"]
    token = old_sha or "ABSENT"
    return (
        f"channels/candidate/transitions/{token}.json",
        canonical(
            {
                "oldPointerSha256": old_sha,
                "planSha256": hashlib.sha256(raw).hexdigest(),
                "product": "uten-imp",
                "schemaVersion": 1,
                "signedPublicationSha256": value["signedPublicationSha256"],
                "targetReleaseSequence": offline_release.validate_version(
                    value["version"]
                ),
                "targetVersion": value["version"],
            }
        ),
    )


class OssPlanAndApplyTest(unittest.TestCase):
    def test_bootstrap_plan_is_create_only_and_latest_is_last(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            publication, receipt = signed_publication_fixture(root)
            output = root / "plan.json"
            allowed = root / "allowed_signers"
            allowed.write_bytes(b"uten-imp-release ssh-ed25519 TEST\n")
            with mock.patch.object(
                offline_release, "fixed_executable", return_value=Path("ssh-keygen")
            ), mock.patch.object(offline_release, "_ssh_verify") as verify, mock.patch.object(
                offline_release, "run_tool"
            ) as run_tool:
                offline_release.command_plan_oss(
                    argparse.Namespace(
                        signed_publication=publication,
                        publication_receipt=receipt,
                        bucket="uten-test",
                        endpoint="https://oss.example.invalid",
                        region="cn-test-1",
                        confirmation=offline_release.CONFIRM_BOOTSTRAP,
                        current_pointer=None,
                        current_channel=None,
                        current_channel_signature=None,
                        allowed_signers=allowed,
                        expected_allowed_signers_sha256=hashlib.sha256(allowed.read_bytes()).hexdigest(),
                        ssh_keygen=Path("ssh-keygen"),
                        expected_ssh_keygen_sha256="1" * 64,
                        release_guard=Path("release_guard.py"),
                        expected_release_guard_sha256="2" * 64,
                        decision_validator=Path("decision_validator.py"),
                        expected_decision_validator_sha256="3" * 64,
                        output_plan=output,
                    )
                )
            self.assertEqual(verify.call_count, 4)
            self.assertEqual(run_tool.call_count, 3)
            plan, _ = offline_release.load_json(output, "plan")
            self.assertTrue(plan["bootstrap"])
            self.assertEqual(plan["region"], "cn-test-1")
            self.assertEqual(plan["operations"][-1]["objectKey"], "channels/candidate/LATEST.txt")
            self.assertTrue(all(item["createOnly"] for item in plan["operations"]))
            object_keys = {
                item["localName"]: item["objectKey"]
                for item in plan["operations"][:-1]
            }
            self.assertEqual(
                object_keys["channel.json"],
                f"channels/candidate/{VERSION}.json",
            )
            self.assertEqual(
                object_keys["backend.cdx.json"],
                f"releases/{VERSION}/sbom/backend.cdx.json",
            )
            self.assertEqual(
                object_keys["updater-wheelhouse.attestation.json"],
                f"releases/{VERSION}/sbom/updater/updater-wheelhouse.attestation.json",
            )

    def test_plan_rejects_repacked_standalone_sbom_or_sidecar(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            publication, receipt = signed_publication_fixture(root)
            artifact_name = f"uten-imp-{VERSION}-{COMMIT[:12]}.tar.gz"
            allowed = root / "allowed-signers"
            allowed.write_bytes(b"uten-imp-release ssh-ed25519 TEST\n")
            for index, replacements in enumerate(
                (
                    {"backend.cdx.json": b'{"bomFormat":"CycloneDX","tampered":true}\n'},
                    {f"{artifact_name}.sha256": b"0" * 64 + b"  wrong.tar.gz\n"},
                )
            ):
                tampered = rewrite_signed_publication(
                    publication,
                    root / f"tampered-{index}.tar",
                    replacements,
                )
                receipt_value, _ = offline_release.load_json(
                    receipt, "publication receipt"
                )
                receipt_value["signedPublicationSha256"] = hashlib.sha256(
                    tampered.read_bytes()
                ).hexdigest()
                tampered_receipt = root / f"tampered-{index}-receipt.json"
                tampered_receipt.write_bytes(canonical(receipt_value))
                with self.assertRaisesRegex(
                    offline_release.ReleaseError, "SBOM|sidecar"
                ):
                    offline_release.command_plan_oss(
                        argparse.Namespace(
                            signed_publication=tampered,
                            publication_receipt=tampered_receipt,
                            bucket="uten-test",
                            endpoint="https://oss.example.invalid",
                            region="cn-test-1",
                            confirmation=offline_release.CONFIRM_BOOTSTRAP,
                            current_pointer=None,
                            current_channel=None,
                            current_channel_signature=None,
                            allowed_signers=allowed,
                            expected_allowed_signers_sha256=hashlib.sha256(
                                allowed.read_bytes()
                            ).hexdigest(),
                            ssh_keygen=Path("ssh-keygen"),
                            expected_ssh_keygen_sha256="1" * 64,
                            release_guard=Path("release_guard.py"),
                            expected_release_guard_sha256="2" * 64,
                            decision_validator=Path("decision_validator.py"),
                            expected_decision_validator_sha256="3" * 64,
                            output_plan=root / f"must-not-exist-{index}.json",
                        )
                    )

    def test_apply_reads_every_object_back_and_never_deletes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            publication, plan, _files = oss_apply_fixture(root)
            remote: dict[str, bytes] = {}
            puts: list[dict] = []

            def fake_put(_ossutil, local, **kwargs):
                puts.append(kwargs)
                remote[kwargs["object_key"]] = local.read_bytes()

            def fake_read(_ossutil, **kwargs):
                self.assertGreater(kwargs["max_bytes"], 0)
                return remote.get(kwargs["object_key"])

            with mock.patch.dict(os.environ, {"OSS_ACCESS_KEY_ID": "temporary", "OSS_ACCESS_KEY_SECRET": "temporary", "OSS_SESSION_TOKEN": "temporary"}, clear=False), mock.patch.object(offline_release, "fixed_executable", return_value=Path("ossutil")), mock.patch.object(offline_release, "oss_put_object", side_effect=fake_put), mock.patch.object(offline_release, "oss_read_object", side_effect=fake_read):
                offline_release.command_apply_oss(
                    argparse.Namespace(
                        plan=plan,
                        expected_plan_sha256=hashlib.sha256(plan.read_bytes()).hexdigest(),
                        confirmation=offline_release.CONFIRM_BOOTSTRAP,
                        signed_publication=publication,
                        ossutil=Path("ossutil"),
                        expected_ossutil_sha256="1" * 64,
                        output_receipt=root / "oss-receipt.json",
                    )
                )
            self.assertEqual(len(puts), 15)
            self.assertEqual(
                puts[0]["object_key"],
                "channels/candidate/transitions/ABSENT.json",
            )
            self.assertEqual(
                puts[-1]["object_key"], "channels/candidate/LATEST.txt"
            )
            self.assertTrue(all(item["create_only"] for item in puts))
            self.assertTrue(puts[-1]["no_store"])
            receipt, _ = offline_release.load_json(root / "oss-receipt.json", "receipt")
            self.assertEqual(receipt["objects"][-1]["objectKey"], "channels/candidate/LATEST.txt")
            self.assertEqual(len(receipt["objects"]), 15)

    def test_apply_prevalidates_every_operation_before_first_remote_read_or_write(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            publication, _valid_plan, _files = oss_apply_fixture(root)
            plan_value, _ = offline_release.load_json(_valid_plan, "valid plan")
            plan_value["operations"][0]["createOnly"] = False
            plan = root / "invalid-plan.json"
            plan.write_bytes(canonical(plan_value))
            with mock.patch.dict(os.environ, {"OSS_ACCESS_KEY_ID": "temporary", "OSS_ACCESS_KEY_SECRET": "temporary", "OSS_SESSION_TOKEN": "temporary"}, clear=False), mock.patch.object(offline_release, "fixed_executable", return_value=Path("ossutil")), mock.patch.object(offline_release, "oss_put_object") as put, mock.patch.object(offline_release, "oss_read_object") as read:
                with self.assertRaisesRegex(offline_release.ReleaseError, "create-only"):
                    offline_release.command_apply_oss(
                        argparse.Namespace(
                            plan=plan,
                            expected_plan_sha256=hashlib.sha256(plan.read_bytes()).hexdigest(),
                            confirmation=offline_release.CONFIRM_BOOTSTRAP,
                            signed_publication=publication,
                            ossutil=Path("ossutil"),
                            expected_ossutil_sha256="1" * 64,
                            output_receipt=root / "must-not-exist.json",
                        )
                    )
            put.assert_not_called()
            read.assert_not_called()
            self.assertFalse((root / "must-not-exist.json").exists())

    def test_apply_resumes_exact_objects_and_already_final_pointer_without_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            publication, plan, files = oss_apply_fixture(root)
            plan_value, _ = offline_release.load_json(plan, "resume plan")
            pointer = f"{VERSION}\n".encode()
            remote = {
                operation["objectKey"]: files[operation["localName"]]
                for operation in plan_value["operations"][:-1]
            }
            transition_key, transition_raw = expected_transition(plan)
            remote[transition_key] = transition_raw
            remote["channels/candidate/LATEST.txt"] = pointer
            with mock.patch.dict(os.environ, {"OSS_ACCESS_KEY_ID": "temporary", "OSS_ACCESS_KEY_SECRET": "temporary", "OSS_SESSION_TOKEN": "temporary"}, clear=False), mock.patch.object(offline_release, "fixed_executable", return_value=Path("ossutil")), mock.patch.object(offline_release, "oss_put_object") as put, mock.patch.object(offline_release, "oss_read_object", side_effect=lambda _tool, **kwargs: remote.get(kwargs["object_key"])):
                offline_release.command_apply_oss(
                    argparse.Namespace(
                        plan=plan,
                        expected_plan_sha256=hashlib.sha256(plan.read_bytes()).hexdigest(),
                        confirmation=offline_release.CONFIRM_BOOTSTRAP,
                        signed_publication=publication,
                        ossutil=Path("ossutil"),
                        expected_ossutil_sha256="1" * 64,
                        output_receipt=root / "resume-receipt.json",
                    )
                )
            put.assert_not_called()
            receipt, _ = offline_release.load_json(root / "resume-receipt.json", "receipt")
            self.assertEqual(len(receipt["objects"]), 15)

    def test_conflicting_old_pointer_transition_fails_before_any_upload(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            publication, plan, _files = oss_apply_fixture(root)
            transition_key, _transition_raw = expected_transition(plan)
            remote = {transition_key: b'{"differentPlan":true}\n'}
            with mock.patch.dict(os.environ, {"OSS_ACCESS_KEY_ID": "temporary", "OSS_ACCESS_KEY_SECRET": "temporary", "OSS_SESSION_TOKEN": "temporary"}, clear=False), mock.patch.object(offline_release, "fixed_executable", return_value=Path("ossutil")), mock.patch.object(offline_release, "oss_put_object") as put, mock.patch.object(offline_release, "oss_read_object", side_effect=lambda _tool, **kwargs: remote.get(kwargs["object_key"])):
                with self.assertRaisesRegex(
                    offline_release.ReleaseError, "already claimed"
                ):
                    offline_release.command_apply_oss(
                        argparse.Namespace(
                            plan=plan,
                            expected_plan_sha256=hashlib.sha256(
                                plan.read_bytes()
                            ).hexdigest(),
                            confirmation=offline_release.CONFIRM_BOOTSTRAP,
                            signed_publication=publication,
                            ossutil=Path("ossutil"),
                            expected_ossutil_sha256="1" * 64,
                            output_receipt=root / "must-not-exist.json",
                        )
                    )
            put.assert_not_called()
            self.assertFalse((root / "must-not-exist.json").exists())

    def test_apply_rejects_signed_publication_not_bound_by_plan(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            publication, plan, _files = oss_apply_fixture(root)
            changed = root / "changed-publication.tar"
            changed.write_bytes(publication.read_bytes() + b"x")
            with mock.patch.object(offline_release, "fixed_executable") as fixed:
                with self.assertRaisesRegex(
                    offline_release.ReleaseError, "differs from the approved"
                ):
                    offline_release.command_apply_oss(
                        argparse.Namespace(
                            plan=plan,
                            expected_plan_sha256=hashlib.sha256(
                                plan.read_bytes()
                            ).hexdigest(),
                            confirmation=offline_release.CONFIRM_BOOTSTRAP,
                            signed_publication=changed,
                            ossutil=Path("ossutil"),
                            expected_ossutil_sha256="1" * 64,
                            output_receipt=root / "must-not-exist.json",
                        )
                    )
            fixed.assert_not_called()

    def test_remote_object_read_is_killed_at_explicit_size_bound(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            captured: list[list[str]] = []

            class OversizeProcess:
                def __init__(self, command, **kwargs):
                    captured.append(command)
                    kwargs["stdout"].write(b"x" * 129)
                    kwargs["stdout"].flush()
                    self.returncode = 0

                def poll(self):
                    return self.returncode

                def kill(self):
                    self.returncode = -9

                def wait(self, timeout=None):
                    return self.returncode

            with mock.patch.object(
                offline_release.subprocess, "Popen", OversizeProcess
            ):
                with self.assertRaisesRegex(
                    offline_release.ReleaseError, "explicit byte bound"
                ):
                    offline_release.oss_read_object(
                        Path("ossutil"),
                        bucket="uten-test",
                        object_key="channels/candidate/LATEST.txt",
                        endpoint="https://oss.example.invalid",
                        region="cn-test-1",
                        environment={"HOME": str(root)},
                        max_bytes=128,
                    )
            self.assertEqual(captured[0][1:3], ["api", "get-object"])
            self.assertIn("--region", captured[0])


if __name__ == "__main__":
    unittest.main()
