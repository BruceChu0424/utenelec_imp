from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


PROJECT_ROOT = Path(__file__).resolve().parents[2]
UPDATER_DIR = PROJECT_ROOT / "deploy" / "updater"
SETUP_DIR = PROJECT_ROOT / "deploy" / "setup"
sys.path.insert(0, str(UPDATER_DIR))

if os.name == "nt":
    sys.modules.setdefault(
        "fcntl",
        types.SimpleNamespace(
            LOCK_EX=2,
            LOCK_NB=4,
            LOCK_UN=8,
            flock=lambda *_args, **_kwargs: None,
        ),
    )
    sys.modules.setdefault(
        "grp",
        types.SimpleNamespace(
            getgrnam=lambda _name: types.SimpleNamespace(gr_gid=0)
        ),
    )
    sys.modules.setdefault(
        "pwd",
        types.SimpleNamespace(
            getpwnam=lambda _name: types.SimpleNamespace(pw_uid=0, pw_gid=0)
        ),
    )


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


commissioner = load_module(
    "internal_test_db_commissioner_bridge_under_test",
    SETUP_DIR / "existing-test-host-internal-db-commissioner.py",
)
preparer = load_module(
    "internal_test_host_preparer_bridge_under_test",
    SETUP_DIR / "prepare-existing-test-host-internal-runtime.py",
)
manifest_builder = load_module(
    "internal_test_host_manifest_builder_bridge_under_test",
    SETUP_DIR / "build-internal-test-reviewed-host-manifest.py",
)
release_updater = load_module(
    "release_updater_bridge_under_test", UPDATER_DIR / "release_updater.py"
)
recovery_boot = load_module(
    "recovery_commit_boot_verifier_bridge_under_test",
    UPDATER_DIR / "recovery_commit_boot_verifier.py",
)
runtime_boot = load_module(
    "runtime_boot_verifier_bridge_under_test",
    UPDATER_DIR / "runtime_boot_verifier.py",
)
recovery_gate = load_module(
    "recovery_ingress_gate_bridge_under_test",
    UPDATER_DIR / "recovery_ingress_gate.py",
)


VERSION = "v2026.08.12-1"
TRANSACTION_ID = "internal-test-db-20260812T120000Z-0123456789ab"
WORKER_BOOT_ID = "11111111-1111-4111-8111-111111111111"
WORKER_UNIT_SHA256 = "d" * 64
WORKER_RUNTIME_CONTRACT_SHA256 = "e" * 64


def fixed_worker_request(approval: str) -> dict[str, object]:
    return commissioner.worker_request_value(
        VERSION,
        approval,
        boot_id=WORKER_BOOT_ID,
        unit_sha256=WORKER_UNIT_SHA256,
        runtime_contract_sha256=WORKER_RUNTIME_CONTRACT_SHA256,
    )


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8")


def write_json(path: Path, value: object) -> bytes:
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = canonical_bytes(value)
    path.write_bytes(raw)
    return raw


def unchecked_strict(path: Path, _label: str):
    raw = path.read_bytes()
    return json.loads(raw.decode("utf-8")), raw


def simulated_root_file(path: Path, *, mode: int | None = None):
    """Exercise path/type/mode checks while simulating root-owned fixtures."""

    try:
        details = path.lstat()
    except FileNotFoundError as exc:
        raise preparer.PreparationError(
            f"required root-controlled file is missing: {path}"
        ) from exc
    if (
        not stat.S_ISREG(details.st_mode)
        or path.is_symlink()
        or details.st_nlink != 1
        or details.st_mode & 0o022
        or (mode is not None and stat.S_IMODE(details.st_mode) != mode)
    ):
        raise preparer.PreparationError(
            f"root-controlled source/target is unsafe: {path}"
        )
    return SimpleNamespace(
        st_dev=details.st_dev,
        st_gid=0,
        st_ino=details.st_ino,
        st_mode=details.st_mode,
        st_nlink=details.st_nlink,
        st_size=details.st_size,
        st_uid=0,
    )


def simulated_root_source_digest(path: Path, _label: str) -> str:
    """Apply the source metadata contract while substituting only uid/gid."""

    details = path.lstat()
    repository_fixture = False
    try:
        path.relative_to(PROJECT_ROOT)
        repository_fixture = True
    except ValueError:
        pass
    if (
        not stat.S_ISREG(details.st_mode)
        or path.is_symlink()
        or details.st_nlink != 1
        or (not repository_fixture and details.st_mode & 0o022)
        or details.st_size < 1
    ):
        raise RuntimeError(
            f"root-controlled source/target is unsafe: {path}"
        )
    return hashlib.sha256(path.read_bytes()).hexdigest()


def simulated_stable_root_source(
    path: Path,
    label: str,
    *,
    expected_mode: int | None = None,
) -> tuple[bytes, str]:
    """Simulate only root uid/gid while retaining the stable-source policy."""

    details = path.lstat()
    repository_fixture = False
    try:
        path.relative_to(PROJECT_ROOT)
        repository_fixture = True
    except ValueError:
        pass
    if (
        not stat.S_ISREG(details.st_mode)
        or path.is_symlink()
        or details.st_nlink != 1
        or (not repository_fixture and details.st_mode & 0o022)
        or (
            expected_mode is not None
            and stat.S_IMODE(details.st_mode) != expected_mode
        )
        or details.st_size < 1
    ):
        raise RuntimeError(
            f"reviewed {label} is not an immutable root-owned regular file"
        )
    payload = path.read_bytes()
    return payload, hashlib.sha256(payload).hexdigest()


def simulated_stable_root_digest(
    path: Path,
    *,
    mode: int,
    maximum_bytes: int = 16 * 1024 * 1024,
) -> str:
    details = simulated_root_file(path, mode=mode)
    if not 1 <= details.st_size <= maximum_bytes:
        raise preparer.PreparationError(
            f"root digest input size is unsafe: {path}"
        )
    return hashlib.sha256(path.read_bytes()).hexdigest()


def simulated_root_directory(path: Path, *, mode: int | None = None):
    try:
        details = path.lstat()
    except FileNotFoundError as exc:
        raise preparer.PreparationError(
            f"required root-controlled directory is missing: {path}"
        ) from exc
    if (
        not stat.S_ISDIR(details.st_mode)
        or path.is_symlink()
        or details.st_mode & 0o022
        or (mode is not None and stat.S_IMODE(details.st_mode) != mode)
    ):
        raise preparer.PreparationError(
            f"root-controlled directory is unsafe: {path}"
        )
    return SimpleNamespace(
        st_dev=details.st_dev,
        st_gid=0,
        st_ino=details.st_ino,
        st_mode=details.st_mode,
        st_nlink=details.st_nlink,
        st_size=details.st_size,
        st_uid=0,
    )


def simulated_atomic(
    path: Path, payload: bytes, mode: int, *, replace: bool = False
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if os.path.lexists(path) and not replace:
        raise preparer.PreparationError(
            f"refusing to overwrite existing target without preimage authority: {path}"
        )
    incoming = path.parent / f".{path.name}.bridge-test-incoming"
    if os.path.lexists(incoming):
        raise AssertionError(f"stale bridge-test incoming path: {incoming}")
    incoming.write_bytes(payload)
    incoming.chmod(mode)
    os.replace(incoming, path)


@contextlib.contextmanager
def simulated_preparer_root_filesystem():
    with mock.patch.object(
        preparer, "root_file", side_effect=simulated_root_file
    ), mock.patch.object(
        preparer, "root_directory", side_effect=simulated_root_directory
    ), mock.patch.object(
        preparer, "atomic", side_effect=simulated_atomic
    ), mock.patch.object(
        preparer, "fsync_directory"
    ), mock.patch.object(
        preparer.os, "chown", create=True
    ) as chown, mock.patch.object(
        preparer.os, "O_NOFOLLOW", 0, create=True
    ), mock.patch.object(
        preparer.grp,
        "getgrnam",
        return_value=SimpleNamespace(gr_gid=4242),
    ), mock.patch.object(
        preparer,
        "run",
        return_value=subprocess.CompletedProcess([], 0, b"", b""),
    ) as run:
        yield SimpleNamespace(chown=chown, run=run)


class EmployeeListenerObservationContractTest(unittest.TestCase):
    """The two root workflows must parse the same bounded ``ss`` grammar."""

    def test_malformed_udp_listener_rows_fail_closed_in_both_root_workflows(self):
        malformed = {
            # ``ss -H -lunp`` always has state, recv-q, send-q, local and peer.
            # Treating a four-column line as complete can silently reinterpret
            # an endpoint after output truncation or format drift.
            "missing-peer-column": b"UNCONN 0 0 *:9999\n",
            "unknown-state": b"LISTEN 0 0 *:9999 *:*\n",
            "service-name-port": b"UNCONN 0 0 *:https *:*\n",
            "non-ascii": b"UNCONN 0 0 *:9999 *:* \xff\n",
            "oversized": b"x" * (1024 * 1024 + 1),
        }
        workflows = (
            (preparer, preparer.PreparationError, True),
            (commissioner, commissioner.CommissioningError, False),
        )
        for case, udp in malformed.items():
            for module, error, capture in workflows:
                with self.subTest(case=case, workflow=module.__name__):
                    def observe(command, **kwargs):
                        self.assertEqual(capture, kwargs.get("capture", False))
                        payload = b"" if "-ltnp" in command else udp
                        return subprocess.CompletedProcess(command, 0, payload, b"")

                    with mock.patch.object(module, "run", side_effect=observe) as run:
                        with self.assertRaises(error):
                            module.require_employee_ports_closed()
                    self.assertLessEqual(run.call_count, 2)

    def test_canonical_udp_row_without_process_column_is_accepted(self):
        workflows = ((preparer, True), (commissioner, False))
        for module, capture in workflows:
            with self.subTest(workflow=module.__name__):
                def observe(command, **kwargs):
                    self.assertEqual(capture, kwargs.get("capture", False))
                    payload = (
                        b"" if "-ltnp" in command else b"UNCONN 0 0 *:9999 *:*\n"
                    )
                    return subprocess.CompletedProcess(command, 0, payload, b"")

                with mock.patch.object(module, "run", side_effect=observe):
                    module.require_employee_ports_closed()


class CommissionerCandidatePathContractTest(unittest.TestCase):
    def fixture(self, root: Path):
        evidence = root / TRANSACTION_ID
        build = evidence / "candidate-build-1"
        metadata = build / "candidate-metadata"
        payload = build / "payload" / VERSION
        metadata.mkdir(parents=True)
        payload.mkdir(parents=True)
        plan = {
            "candidateMetadataPath": str(metadata),
            "candidatePayloadPath": str(payload),
        }
        return evidence, metadata, payload, plan

    def test_producer_accepts_only_one_bound_build_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence, metadata, payload, plan = self.fixture(Path(directory))
            with mock.patch.object(commissioner, "require_root_directory"):
                actual = commissioner.candidate_paths_from_plan(
                    evidence, plan, VERSION
                )
        self.assertEqual((metadata, payload), actual)

    def test_producer_rejects_sibling_and_lexical_escape_before_metadata_trust(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence, metadata, payload, plan = self.fixture(Path(directory))
            sibling = evidence / "candidate-build-2"
            cases = {
                "metadata-sibling": {
                    **plan,
                    "candidateMetadataPath": str(sibling / "candidate-metadata"),
                },
                "payload-sibling": {
                    **plan,
                    "candidatePayloadPath": str(sibling / "payload" / VERSION),
                },
                "metadata-parent-traversal": {
                    **plan,
                    "candidateMetadataPath": str(
                        evidence
                        / "candidate-build-1"
                        / "payload"
                        / ".."
                        / "candidate-metadata"
                    ),
                },
                "payload-parent-traversal": {
                    **plan,
                    "candidatePayloadPath": str(
                        payload.parent / ".." / "payload" / VERSION
                    ),
                },
            }
            for label, changed in cases.items():
                with self.subTest(label=label), mock.patch.object(
                    commissioner, "require_root_directory"
                ) as require_directory:
                    with self.assertRaisesRegex(
                        commissioner.CommissioningError, "escaped"
                    ):
                        commissioner.candidate_paths_from_plan(
                            evidence, changed, VERSION
                        )
                    require_directory.assert_not_called()

    def test_producer_and_updater_consumer_share_the_exact_path_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence, metadata, payload, plan = self.fixture(Path(directory))
            with mock.patch.object(commissioner, "require_root_directory"):
                produced = commissioner.candidate_paths_from_plan(
                    evidence, plan, VERSION
                )
            consumed = (
                release_updater.validate_internal_test_commissioning_candidate_paths(
                    evidence, plan, VERSION
                )
            )
            self.assertEqual((metadata, payload), produced)
            self.assertEqual(produced, consumed)

            escaped = {
                **plan,
                "candidatePayloadPath": str(
                    evidence / "candidate-build-2" / "payload" / VERSION
                ),
            }
            with mock.patch.object(
                commissioner, "require_root_directory"
            ), self.assertRaises(commissioner.CommissioningError):
                commissioner.candidate_paths_from_plan(evidence, escaped, VERSION)
            with self.assertRaises(release_updater.UpdaterError):
                release_updater.validate_internal_test_commissioning_candidate_paths(
                    evidence, escaped, VERSION
                )


class CandidateSnapshotAttemptLimitTest(unittest.TestCase):
    class StatProxy:
        def __init__(self, details):
            self._details = details
            self.st_uid = 0
            self.st_gid = 0

        def __getattr__(self, name):
            return getattr(self._details, name)

    def test_third_failed_generation_is_retained_then_reentry_stays_terminal(self):
        self.assertEqual(3, commissioner.MAX_CANDIDATE_BUILD_ATTEMPTS)
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / TRANSACTION_ID
            evidence.mkdir(mode=0o700)
            for attempt in range(1, 4):
                attempt_path = evidence / f"candidate-build-attempt-{attempt}.json"
                write_json(
                    attempt_path,
                    {
                        "buildPath": str(evidence / f"candidate-build-{attempt}"),
                        "kind": "uten-imp-internal-test-candidate-build-attempt",
                        "schemaVersion": 1,
                        "status": "AUTHORIZED_ENTRY_CLOSED",
                        "transactionId": evidence.name,
                        "version": VERSION,
                    },
                )
                attempt_path.chmod(0o600)
            for attempt in (1, 2):
                incomplete = evidence / f"candidate-build-incomplete-{attempt}"
                incomplete.mkdir(mode=0o700)
                authority_path = (
                    evidence / f"candidate-build-abandon-authorized-{attempt}.json"
                )
                write_json(
                    authority_path,
                    {"fixture": True},
                )
                authority_path.chmod(0o600)
                abandoned_path = evidence / f"candidate-build-abandoned-{attempt}.json"
                write_json(
                    abandoned_path,
                    {
                        "attempt": attempt,
                        "incompletePath": str(incomplete),
                        "kind": "uten-imp-internal-test-candidate-build-abandoned",
                        "schemaVersion": 1,
                        "status": "RETAINED_ENTRY_CLOSED",
                        "transactionId": evidence.name,
                    },
                )
                abandoned_path.chmod(0o600)
            live_third = evidence / "candidate-build-3"
            live_third.mkdir(mode=0o700)
            updater = SimpleNamespace(snapshot_candidate=mock.Mock())
            guard = SimpleNamespace(safe_extract=mock.Mock(), verify_payload=mock.Mock())
            real_lstat = type(evidence).lstat

            def root_evidence_lstat(path: Path, *args, **kwargs):
                details = real_lstat(path, *args, **kwargs)
                try:
                    path.relative_to(evidence)
                except ValueError:
                    return details
                return self.StatProxy(details)

            def atomic(path: Path, value: object, **_kwargs):
                write_json(path, value)
                path.chmod(0o600)

            with mock.patch.object(
                commissioner, "require_root_directory"
            ), mock.patch.object(
                commissioner, "fsync_directory"
            ), mock.patch.object(
                commissioner, "atomic_json", side_effect=atomic
            ) as atomic_json, mock.patch.object(
                type(evidence),
                "lstat",
                autospec=True,
                side_effect=root_evidence_lstat,
            ):
                with self.assertRaisesRegex(
                    commissioner.CommissioningError, "retry limit"
                ):
                    commissioner.candidate_snapshot(
                        updater, guard, VERSION, evidence
                    )
                self.assertFalse(live_third.exists())
                self.assertTrue(
                    (evidence / "candidate-build-incomplete-3").is_dir()
                )
                self.assertTrue(
                    (evidence / "candidate-build-abandon-authorized-3.json").is_file()
                )
                self.assertTrue(
                    (evidence / "candidate-build-abandoned-3.json").is_file()
                )
                self.assertFalse(
                    (evidence / "candidate-build-attempt-4.json").exists()
                )
                self.assertFalse((evidence / "candidate-build-4").exists())
                self.assertEqual(2, atomic_json.call_count)
                updater.snapshot_candidate.assert_not_called()
                guard.safe_extract.assert_not_called()

                atomic_json.reset_mock()
                with self.assertRaisesRegex(
                    commissioner.CommissioningError, "retry limit"
                ):
                    commissioner.candidate_snapshot(
                        updater, guard, VERSION, evidence
                    )
                atomic_json.assert_not_called()
                updater.snapshot_candidate.assert_not_called()
                self.assertEqual(
                    [
                        evidence / "candidate-build-incomplete-1",
                        evidence / "candidate-build-incomplete-2",
                        evidence / "candidate-build-incomplete-3",
                    ],
                    sorted(evidence.glob("candidate-build-incomplete-*")),
                )


class CommissioningAuthorizationExpiryTest(unittest.TestCase):
    APPROVAL = "CHG-2026-0813-EXPIRY"
    RUNTIME_SHA = "1" * 64
    STORAGE_SHA = "2" * 64

    @staticmethod
    def utc(value: datetime) -> str:
        return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    @contextlib.contextmanager
    def fixture(
        self,
        *,
        preactive_created: datetime,
        plan_created: datetime,
        plan_expires: datetime,
    ):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory) / "evidence"
            base.mkdir(mode=0o700)
            evidence = base / TRANSACTION_ID
            evidence.mkdir(mode=0o700)
            preactive_path = base / "pre-active.json"
            active_path = base / "active.json"
            onboarding_path = base / "onboarding.json"
            pgdata = Path(directory) / "pgdata"
            pgdata.mkdir(mode=0o700)
            plan_path = evidence / "transaction-manifest.json"
            preactive = {
                "approvalReference": self.APPROVAL,
                "createdAtUtc": self.utc(preactive_created),
                "evidencePath": str(evidence),
                "runtimeContractSha256": self.RUNTIME_SHA,
                "schemaVersion": 1,
                "status": "PREPARING_ENTRY_CLOSED",
                "storageCommissioningReceiptSha256": self.STORAGE_SHA,
                "transactionId": TRANSACTION_ID,
                "version": VERSION,
            }
            plan = {
                "approvalReference": self.APPROVAL,
                "createdAtUtc": self.utc(plan_created),
                "expiresAtUtc": self.utc(plan_expires),
                "manifest": {"version": VERSION},
                "runtimeContractSha256": self.RUNTIME_SHA,
                "storageCommissioningReceiptSha256": self.STORAGE_SHA,
                "transactionId": TRANSACTION_ID,
            }
            write_json(preactive_path, preactive)
            preactive_path.chmod(0o600)
            write_json(plan_path, plan)
            plan_path.chmod(0o600)

            def atomic(path: Path, value: object, **_kwargs):
                write_json(path, value)
                path.chmod(0o600)

            with contextlib.ExitStack() as stack:
                for name, value in (
                    ("EVIDENCE_BASE", base),
                    ("PREACTIVE_POINTER", preactive_path),
                    ("ACTIVE_POINTER", active_path),
                    ("ONBOARDING_RECEIPT", onboarding_path),
                    ("PGDATA", pgdata),
                ):
                    stack.enter_context(mock.patch.object(commissioner, name, value))
                stack.enter_context(
                    mock.patch.object(commissioner, "require_root_file")
                )
                stack.enter_context(
                    mock.patch.object(commissioner, "require_root_directory")
                )
                atomic_json = stack.enter_context(
                    mock.patch.object(
                        commissioner, "atomic_json", side_effect=atomic
                    )
                )
                stack.enter_context(
                    mock.patch.object(commissioner.os, "chown")
                )
                yield SimpleNamespace(
                    active_path=active_path,
                    atomic_json=atomic_json,
                    base=base,
                    evidence=evidence,
                    onboarding_path=onboarding_path,
                    pgdata=pgdata,
                    plan=plan,
                    plan_path=plan_path,
                    preactive=preactive,
                    preactive_path=preactive_path,
                )

    def test_expired_preactive_or_plan_without_authority_is_zero_mutation(self):
        now = datetime.now(timezone.utc).replace(microsecond=0)
        cases = (
            (
                "expired-preactive",
                now - timedelta(days=8),
                now - timedelta(days=8),
                now - timedelta(days=1),
            ),
            (
                "expired-plan",
                now - timedelta(days=1),
                now - timedelta(hours=2),
                now - timedelta(hours=1),
            ),
        )
        for label, preactive_created, plan_created, plan_expires in cases:
            with self.subTest(case=label), self.fixture(
                preactive_created=preactive_created,
                plan_created=plan_created,
                plan_expires=plan_expires,
            ) as fixture:
                candidate = mock.Mock()
                active = mock.Mock()
                initialize = mock.Mock()
                updater = SimpleNamespace(
                    DatabaseMaintenanceLock=lambda: contextlib.nullcontext(),
                    DEFAULT_LOCK_FILE=Path("/fixed/operation.lock"),
                    StateLock=lambda *_args, **_kwargs: contextlib.nullcontext(),
                    assert_pre_database_runtime_contract=mock.Mock(),
                )
                guard = object()
                storage_receipt = fixture.base / "storage-complete.json"
                with mock.patch.object(
                    commissioner.os, "geteuid", return_value=0
                ), mock.patch.object(
                    commissioner,
                    "bootstrap_runtime_contract",
                    return_value=({}, "f" * 64),
                ), mock.patch.object(
                    commissioner, "load_modules", return_value=(updater, guard)
                ), mock.patch.object(
                    commissioner, "require_entry_closed"
                ), mock.patch.object(
                    commissioner,
                    "runtime_contract",
                    return_value=({"deploymentProfile": "internal-test-local-v1"}, self.RUNTIME_SHA),
                ), mock.patch.object(
                    commissioner, "verify_runtime_secret_binding"
                ), mock.patch.object(
                    commissioner,
                    "storage_receipt",
                    return_value=(storage_receipt, {}, self.STORAGE_SHA),
                ), mock.patch.object(
                    commissioner, "validate_storage_terminal_contract"
                ), mock.patch.object(
                    commissioner, "verify_live_storage", return_value={}
                ), mock.patch.object(
                    commissioner, "pgdata_empty", return_value=True
                ), mock.patch.object(
                    commissioner, "candidate_snapshot", candidate
                ), mock.patch.object(
                    commissioner, "write_active_pointer", active
                ), mock.patch.object(
                    commissioner, "initialize_cluster", initialize
                ), self.assertRaises(commissioner.CommissioningError):
                    commissioner.apply(VERSION, self.APPROVAL)

                candidate.assert_not_called()
                active.assert_not_called()
                initialize.assert_not_called()
                fixture.atomic_json.assert_not_called()
                self.assertFalse(fixture.active_path.exists())
                self.assertEqual([], list(fixture.pgdata.iterdir()))
                self.assertFalse(
                    (fixture.evidence / commissioner.COMMISSIONING_AUTHORITY_NAME).exists()
                )

    def test_preexpiry_authority_allows_exact_resume_after_expiry(self):
        now = datetime.now(timezone.utc).replace(microsecond=0)
        created = now - timedelta(minutes=5)
        expires = now + timedelta(minutes=5)
        with self.fixture(
            preactive_created=created,
            plan_created=created,
            plan_expires=expires,
        ) as fixture, mock.patch.object(
            commissioner, "utc_now", return_value=self.utc(now)
        ):
            authority = commissioner.authorize_or_resume_commissioning(
                fixture.evidence, fixture.plan
            )
            self.assertEqual(self.utc(now), authority["authorizedAtUtc"])
            fixture.atomic_json.assert_called_once()

            class LateDateTime(datetime):
                @classmethod
                def now(cls, tz=None):
                    late = expires + timedelta(days=30)
                    return late if tz is None else late.astimezone(tz)

            fixture.atomic_json.reset_mock()
            with mock.patch.object(commissioner, "datetime", LateDateTime):
                resumed = commissioner.authorize_or_resume_commissioning(
                    fixture.evidence, fixture.plan
                )
            self.assertEqual(authority, resumed)
            fixture.atomic_json.assert_not_called()

    def test_forged_late_authority_is_rejected(self):
        now = datetime.now(timezone.utc).replace(microsecond=0)
        created = now - timedelta(minutes=5)
        expires = now + timedelta(minutes=5)
        with self.fixture(
            preactive_created=created,
            plan_created=created,
            plan_expires=expires,
        ) as fixture, mock.patch.object(
            commissioner, "utc_now", return_value=self.utc(now)
        ):
            authority = commissioner.authorize_or_resume_commissioning(
                fixture.evidence, fixture.plan
            )
            authority["authorizedAtUtc"] = self.utc(expires)
            authority_path = (
                fixture.evidence / commissioner.COMMISSIONING_AUTHORITY_NAME
            )
            write_json(authority_path, authority)
            authority_path.chmod(0o600)
            with self.assertRaisesRegex(
                commissioner.CommissioningError, "outside the plan window"
            ):
                commissioner.validate_commissioning_authority(
                    fixture.evidence, fixture.plan
                )

    def test_live_preactive_rename_crash_is_adopted_without_reauthorization(self):
        now = datetime.now(timezone.utc).replace(microsecond=0)
        created = now - timedelta(minutes=5)
        expires = now + timedelta(minutes=5)
        with self.fixture(
            preactive_created=created,
            plan_created=created,
            plan_expires=expires,
        ) as fixture, mock.patch.object(
            commissioner, "utc_now", return_value=self.utc(now)
        ):
            commissioner.authorize_or_resume_commissioning(
                fixture.evidence, fixture.plan
            )
            write_json(
                fixture.active_path,
                {
                    "evidencePath": str(fixture.evidence),
                    "planSha256": commissioner.sha256_file(fixture.plan_path),
                    "schemaVersion": 1,
                    "transactionId": fixture.evidence.name,
                },
            )
            fixture.active_path.chmod(0o600)
            archive = fixture.evidence / commissioner.PREACTIVE_ARCHIVE_NAME
            calls = 0

            def crash_after_rename(_path: Path):
                nonlocal calls
                calls += 1
                if calls == 1:
                    raise OSError("injected crash after pre-active rename")

            with mock.patch.object(
                commissioner,
                "fsync_directory",
                side_effect=crash_after_rename,
            ), self.assertRaisesRegex(OSError, "after pre-active rename"):
                commissioner.converge_preactive_after_active(fixture.evidence)
            self.assertFalse(fixture.preactive_path.exists())
            self.assertTrue(archive.is_file())
            original = archive.read_bytes()

            fixture.atomic_json.reset_mock()
            with mock.patch.object(commissioner, "fsync_directory"):
                commissioner.converge_preactive_after_active(fixture.evidence)
            self.assertEqual(original, archive.read_bytes())
            fixture.atomic_json.assert_not_called()


class FixedWorkspaceCrashConvergenceTest(unittest.TestCase):
    class Lock:
        def __init__(self, *_args, **_kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

    class StatProxy:
        def __init__(self, details, *, uid: int | None = None, gid: int | None = None):
            self._details = details
            self.st_uid = details.st_uid if uid is None else uid
            self.st_gid = details.st_gid if gid is None else gid

        def __getattr__(self, name):
            return getattr(self._details, name)

    @staticmethod
    def require_directory_without_owner(path: Path, *, owner_uid: int):
        details = path.lstat()
        if not stat.S_ISDIR(details.st_mode) or path.is_symlink():
            raise release_updater.UpdaterError(
                f"required real directory is unsafe: {path}"
            )
        return details

    @contextlib.contextmanager
    def snapshot_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = root / VERSION
            candidate.mkdir(mode=0o700)
            releases = root / "releases"
            releases.mkdir(mode=0o700)
            allowed_signers = root / "allowed-signers"
            allowed_signers.write_bytes(b"fixture\n")
            artifact = b"signed archive fixture bytes"
            payloads = {
                "channel.json": b'{"channel":"stable"}\n',
                "channel.sig": b"channel signature\n",
                "manifest.json": b'{"version":"fixture"}\n',
                "manifest.sig": b"manifest signature\n",
                "STAGED.json": b'{"payloadVerified":true}\n',
                "release.tar.zst": artifact,
            }
            for name, raw in payloads.items():
                path = candidate / name
                path.write_bytes(raw)
                path.chmod(0o600)
            manifest_info = {
                "artifactFileName": "release.tar.zst",
                "artifactSizeBytes": len(artifact),
                "uncompressedBytes": 1024,
                "version": VERSION,
            }
            snapshot = releases / f".candidate-snapshot-{VERSION}"
            real_lstat = type(candidate).lstat

            def root_snapshot_lstat(path: Path, *args, **kwargs):
                details = real_lstat(path, *args, **kwargs)
                try:
                    inside_snapshot = path == snapshot or path.is_relative_to(snapshot)
                except ValueError:
                    inside_snapshot = False
                if inside_snapshot:
                    return self.StatProxy(details, uid=0, gid=0)
                return details

            with mock.patch.object(
                release_updater.pwd,
                "getpwnam",
                return_value=SimpleNamespace(pw_uid=os.getuid()),
            ), mock.patch.object(
                release_updater,
                "require_real_directory",
                side_effect=self.require_directory_without_owner,
            ), mock.patch.object(
                release_updater.os, "chown"
            ), mock.patch.object(
                release_updater, "fsync_directory"
            ), mock.patch.object(
                release_updater, "require_capacity"
            ), mock.patch.object(
                release_updater,
                "verify_candidate_metadata",
                return_value=({}, manifest_info, {}),
            ), mock.patch.object(
                release_updater,
                "verify_candidate",
                return_value=({}, manifest_info, {}),
            ), mock.patch.object(
                type(candidate),
                "lstat",
                autospec=True,
                side_effect=root_snapshot_lstat,
            ):
                yield SimpleNamespace(
                    allowed_signers=allowed_signers,
                    candidate=candidate,
                    manifest_info=manifest_info,
                    releases=releases,
                    snapshot=snapshot,
                )

    @unittest.skipUnless(os.name == "posix", "fd snapshot ownership is POSIX-only")
    def test_candidate_snapshot_reuses_one_fixed_exact_directory_and_rejects_drift(self):
        with self.snapshot_fixture() as fixture:
            first, _ = release_updater.snapshot_candidate(
                fixture.candidate, fixture.releases, fixture.allowed_signers
            )
            first_bytes = {
                path.name: path.read_bytes()
                for path in first.iterdir()
                if path.is_file()
            }
            second, _ = release_updater.snapshot_candidate(
                fixture.candidate, fixture.releases, fixture.allowed_signers
            )
            self.assertEqual(fixture.snapshot, first)
            self.assertEqual(first, second)
            self.assertEqual(
                [fixture.snapshot],
                list(fixture.releases.glob(".candidate-snapshot-*")),
            )
            self.assertEqual(
                first_bytes,
                {
                    path.name: path.read_bytes()
                    for path in second.iterdir()
                    if path.is_file()
                },
            )

            (fixture.candidate / "channel.json").write_bytes(
                b'{"channel":"drifted"}\n'
            )
            with self.assertRaisesRegex(
                release_updater.UpdaterError, "differs from resumable snapshot"
            ):
                release_updater.snapshot_candidate(
                    fixture.candidate,
                    fixture.releases,
                    fixture.allowed_signers,
                )
            self.assertFalse(fixture.snapshot.exists())

    @contextlib.contextmanager
    def install_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            releases = root / "releases"
            releases.mkdir(mode=0o700)
            candidate = root / "candidate"
            candidate.mkdir(mode=0o700)
            artifact_name = "release.tar.zst"
            for name, raw in {
                artifact_name: b"archive\n",
                "channel.json": b"channel\n",
                "channel.sig": b"channel signature\n",
                "manifest.json": b"manifest\n",
                "manifest.sig": b"manifest signature\n",
                "STAGED.json": b"staged\n",
            }.items():
                (candidate / name).write_bytes(raw)
            manifest_info = {
                "artifactFileName": artifact_name,
                "version": VERSION,
            }
            temporary = releases / f".install-{VERSION}"
            target = releases / VERSION

            def safe_extract(_archive: Path, parent: Path, _manifest):
                self.assertEqual(temporary, parent)
                self.assertFalse((parent / "partial-from-kill").exists())
                extracted = parent / "extracted"
                (extracted / "server").mkdir(parents=True)
                (extracted / "server/app.jar").write_bytes(b"jar\n")
                return extracted

            verified: list[Path] = []

            def verify_target(_candidate: Path, actual: Path, _manifest):
                self.assertTrue(actual.is_dir())
                verified.append(actual)

            with mock.patch.object(
                release_updater,
                "require_real_directory",
                side_effect=self.require_directory_without_owner,
            ), mock.patch.object(
                release_updater, "require_root_owned_tree"
            ), mock.patch.object(
                release_updater.release_guard,
                "safe_extract",
                side_effect=safe_extract,
            ) as extract, mock.patch.object(
                release_updater.release_guard, "verify_payload"
            ), mock.patch.object(
                release_updater,
                "verify_installed_release_target",
                side_effect=verify_target,
            ), mock.patch.object(
                release_updater, "fsync_directory"
            ), mock.patch.object(
                release_updater, "fsync_tree"
            ), mock.patch.object(
                release_updater.os, "chown"
            ):
                yield SimpleNamespace(
                    candidate=candidate,
                    extract=extract,
                    manifest_info=manifest_info,
                    releases=releases,
                    target=target,
                    temporary=temporary,
                    verified=verified,
                )

    def test_install_workspace_rebuilds_partial_and_converges_after_target_publish(self):
        with self.install_fixture() as fixture:
            fixture.temporary.mkdir(mode=0o700)
            (fixture.temporary / "partial-from-kill").write_bytes(b"partial\n")
            result = release_updater.install_root_owned_release(
                fixture.candidate, fixture.releases, fixture.manifest_info
            )
            self.assertEqual(fixture.target, result)
            self.assertTrue(fixture.target.is_dir())
            self.assertFalse(fixture.temporary.exists())
            self.assertEqual([fixture.target], fixture.verified)
            fixture.extract.assert_called_once()

            # Simulate the later crash boundary: target publish succeeded but
            # the deterministic install workspace was not removed.
            fixture.temporary.mkdir(mode=0o700)
            (fixture.temporary / "partial-from-kill").write_bytes(b"stale\n")
            fixture.extract.reset_mock()
            result = release_updater.install_root_owned_release(
                fixture.candidate, fixture.releases, fixture.manifest_info
            )
            self.assertEqual(fixture.target, result)
            self.assertFalse(fixture.temporary.exists())
            fixture.extract.assert_not_called()
            self.assertEqual([fixture.target, fixture.target], fixture.verified)

    def test_install_workspace_symlink_or_wrong_mode_is_refused_untouched(self):
        for case in ("symlink", "wrong-mode"):
            with self.subTest(case=case), self.install_fixture() as fixture:
                sentinel = fixture.releases / "outside-sentinel"
                sentinel.mkdir(mode=0o700)
                (sentinel / "keep").write_bytes(b"keep\n")
                if case == "symlink":
                    try:
                        fixture.temporary.symlink_to(sentinel, target_is_directory=True)
                    except OSError as exc:
                        self.skipTest(f"fixture cannot create a symlink: {exc}")
                else:
                    fixture.temporary.mkdir(mode=0o755)
                    (fixture.temporary / "keep").write_bytes(b"keep\n")

                with self.assertRaises(release_updater.UpdaterError):
                    release_updater.install_root_owned_release(
                        fixture.candidate,
                        fixture.releases,
                        fixture.manifest_info,
                    )
                fixture.extract.assert_not_called()
                self.assertEqual(b"keep\n", (sentinel / "keep").read_bytes())
                self.assertTrue(os.path.lexists(fixture.temporary))

    def test_recovery_transaction_has_one_action_bound_name_and_safe_reentry(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / "recovery-evidence"
            evidence.mkdir(mode=0o700)
            plan_sha = "d" * 64
            with mock.patch.object(
                release_updater, "RECOVERY_EVIDENCE_DIR", evidence
            ), mock.patch.object(
                release_updater,
                "require_real_directory",
                side_effect=self.require_directory_without_owner,
            ), mock.patch.object(
                release_updater.os, "chown"
            ), mock.patch.object(
                release_updater, "fsync_directory"
            ):
                first = release_updater.create_recovery_transaction(
                    plan_sha, "restore-previous"
                )
                second = release_updater.create_recovery_transaction(
                    plan_sha, "restore-previous"
                )
                self.assertEqual(
                    evidence / ("d" * 16 + "-restore-previous"), first
                )
                self.assertEqual(first, second)
                self.assertEqual([first], list(evidence.iterdir()))

                first.chmod(0o750)
                with self.assertRaisesRegex(
                    release_updater.UpdaterError, "unsafe permissions"
                ):
                    release_updater.create_recovery_transaction(
                        plan_sha, "restore-previous"
                    )
                with self.assertRaisesRegex(
                    release_updater.UpdaterError, "unsupported"
                ):
                    release_updater.create_recovery_transaction(plan_sha, "guess")
                self.assertEqual([first], list(evidence.iterdir()))

    @unittest.skipIf(
        getattr(os, "geteuid", lambda: -1)() == 0,
        "staging positive path requires the dedicated unprivileged updater identity",
    )
    def test_staging_reuses_one_bounded_workspace_and_refuses_unsafe_preimages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            state.mkdir(mode=0o750)
            allowed = root / "allowed-signers"
            allowed.write_bytes(b"fixture\n")
            lock = root / "lock"
            lock.write_bytes(b"")
            work = state / ".incoming-candidate"
            args = SimpleNamespace(
                allowed_signers=str(allowed),
                lock_file=str(lock),
                state_dir=str(state),
            )

            calls: list[Path] = []

            def fail_download(_key: str, destination: Path, _maximum: int):
                calls.append(destination)
                self.assertEqual(work / "LATEST.txt", destination)
                self.assertFalse((work / "partial-from-kill").exists())
                raise release_updater.UpdaterError("injected download boundary")

            patches = (
                mock.patch.object(release_updater, "StateLock", self.Lock),
                mock.patch.object(release_updater, "report_capacity"),
                mock.patch.object(
                    release_updater, "authorized_key_ids", return_value={"fixture"}
                ),
                mock.patch.object(
                    release_updater, "oss_download", side_effect=fail_download
                ),
                mock.patch.object(release_updater, "fsync_directory"),
            )
            with contextlib.ExitStack() as stack:
                for active_patch in patches:
                    stack.enter_context(active_patch)
                for _attempt in range(2):
                    work.mkdir(mode=0o700)
                    (work / "partial-from-kill").write_bytes(b"partial\n")
                    with self.assertRaisesRegex(
                        release_updater.UpdaterError, "download boundary"
                    ):
                        release_updater.stage_release(args)
                    self.assertFalse(work.exists())
                    self.assertEqual([], list(state.glob(".incoming-candidate-*")))
            self.assertEqual(2, len(calls))

            sentinel = root / "outside"
            sentinel.mkdir(mode=0o700)
            (sentinel / "keep").write_bytes(b"keep\n")
            for case in ("symlink", "wrong-owner", "wrong-mode"):
                with self.subTest(case=case):
                    if os.path.lexists(work):
                        if work.is_symlink():
                            work.unlink()
                        else:
                            work.chmod(0o700)
                            for child in work.iterdir():
                                child.unlink()
                            work.rmdir()
                    if case == "symlink":
                        try:
                            work.symlink_to(sentinel, target_is_directory=True)
                        except OSError as exc:
                            self.skipTest(f"fixture cannot create a symlink: {exc}")
                    else:
                        work.mkdir(mode=0o700 if case == "wrong-owner" else 0o755)
                        (work / "keep").write_bytes(b"keep\n")

                    real_lstat = type(work).lstat

                    def drift_owner(path: Path, *args, **kwargs):
                        details = real_lstat(path, *args, **kwargs)
                        if case == "wrong-owner" and path == work:
                            return self.StatProxy(details, uid=os.geteuid() + 1)
                        return details

                    with contextlib.ExitStack() as stack:
                        for active_patch in patches:
                            stack.enter_context(active_patch)
                        stack.enter_context(
                            mock.patch.object(
                                type(work),
                                "lstat",
                                autospec=True,
                                side_effect=drift_owner,
                            )
                        )
                        with self.assertRaises(release_updater.UpdaterError):
                            release_updater.stage_release(args)
                    self.assertTrue(os.path.lexists(work))
                    self.assertEqual(b"keep\n", (sentinel / "keep").read_bytes())


class CommissionerProcessContainmentTest(unittest.TestCase):
    class FakeProcess:
        def __init__(self, *, failure: BaseException | None = None):
            self.failure = failure
            self.pid = 4242
            self.returncode = 0
            self.wait_calls: list[int | None] = []

        def communicate(self, *, input, timeout):
            if self.failure is not None:
                raise self.failure
            return b"stdout", b"stderr"

        def poll(self):
            return None if self.failure is not None else self.returncode

        def wait(self, timeout=None):
            self.wait_calls.append(timeout)
            self.returncode = -9
            return self.returncode

    def test_successful_command_uses_new_session_and_exact_sanitized_environment(self):
        process = self.FakeProcess()
        with mock.patch.object(
            commissioner.subprocess, "Popen", return_value=process
        ) as popen:
            completed = commissioner.run(["/usr/bin/true"])
        self.assertEqual(0, completed.returncode)
        kwargs = popen.call_args.kwargs
        self.assertIs(kwargs["stdin"], commissioner.subprocess.DEVNULL)
        self.assertIs(kwargs["stdout"], commissioner.subprocess.PIPE)
        self.assertIs(kwargs["stderr"], commissioner.subprocess.PIPE)
        self.assertIs(kwargs["start_new_session"], True)
        self.assertEqual(
            {
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
            },
            kwargs["env"],
        )

    @unittest.skipUnless(hasattr(os, "killpg"), "process-group containment is POSIX-only")
    def test_base_exception_kills_and_reaps_the_entire_child_process_group(self):
        for raised in (KeyboardInterrupt(), SystemExit(17)):
            with self.subTest(exception=type(raised).__name__):
                process = self.FakeProcess(failure=raised)
                with mock.patch.object(
                    commissioner.subprocess, "Popen", return_value=process
                ) as popen, mock.patch.object(commissioner.os, "killpg") as killpg:
                    with self.assertRaises(type(raised)):
                        commissioner.run(["/usr/bin/long-running"])
                self.assertIs(popen.call_args.kwargs["start_new_session"], True)
                killpg.assert_called_once_with(4242, commissioner.signal.SIGKILL)
                self.assertEqual([10], process.wait_calls)

    @unittest.skipUnless(hasattr(os, "killpg"), "process-group containment is POSIX-only")
    def test_timeout_kills_and_reaps_the_entire_child_process_group(self):
        process = self.FakeProcess(
            failure=commissioner.subprocess.TimeoutExpired(
                "/usr/bin/long-running", 7
            )
        )
        with mock.patch.object(
            commissioner.subprocess, "Popen", return_value=process
        ), mock.patch.object(commissioner.os, "killpg") as killpg:
            with self.assertRaisesRegex(
                commissioner.CommissioningError, "could not complete"
            ):
                commissioner.run(["/usr/bin/long-running"], timeout=7)
        killpg.assert_called_once_with(4242, commissioner.signal.SIGKILL)
        self.assertEqual([10], process.wait_calls)


class CommissionerFixedCgroupContractTest(unittest.TestCase):
    def supervision_states(self) -> dict[str, str]:
        return {
            "ActiveState": "activating",
            "ControlGroup": commissioner.WORKER_CGROUP,
            "DropInPaths": "",
            "FragmentPath": str(commissioner.COMMISSIONER_UNIT_FILE),
            "KillMode": "control-group",
            "MainPID": str(os.getpid()),
            "UnitFileState": "static",
        }

    def invoke_supervision(self, states: dict[str, str], cgroup: str) -> None:
        real_path = Path

        def controlled_path(value: object):
            if str(value) == "/proc/self/cgroup":
                return SimpleNamespace(
                    read_text=lambda **_kwargs: cgroup
                )
            return real_path(value)

        with mock.patch.object(
            commissioner.os, "geteuid", return_value=0
        ), mock.patch.object(
            commissioner, "require_root_file"
        ), mock.patch.object(
            commissioner, "require_root_directory"
        ), mock.patch.object(
            commissioner,
            "systemd_state",
            side_effect=lambda _unit, name: states[name],
        ), mock.patch.object(
            commissioner, "Path", side_effect=controlled_path
        ):
            commissioner.assert_fixed_worker_supervision()

    def test_worker_accepts_only_its_exact_static_control_group(self):
        self.invoke_supervision(
            self.supervision_states(),
            "0::" + commissioner.WORKER_CGROUP + "\n",
        )

    def test_worker_refuses_wrong_kill_mode_or_another_cgroup(self):
        wrong_mode = self.supervision_states()
        wrong_mode["KillMode"] = "process"
        with self.assertRaisesRegex(
            commissioner.CommissioningError, "KillMode"
        ):
            self.invoke_supervision(
                wrong_mode,
                "0::" + commissioner.WORKER_CGROUP + "\n",
            )

        with self.assertRaisesRegex(
            commissioner.CommissioningError, "outside its fixed systemd cgroup"
        ):
            self.invoke_supervision(
                self.supervision_states(),
                "0::/system.slice/unrelated.service\n",
            )

    def test_fixed_unit_contains_all_worker_children_when_pid1_stops_the_unit(self):
        unit = (
            PROJECT_ROOT
            / "deploy/systemd/uten-imp-internal-db-commissioner.service.example"
        ).read_text(encoding="utf-8")
        self.assertIn("Type=oneshot", unit)
        self.assertIn("RuntimeDirectory=uten-imp-internal-db-commissioner", unit)
        self.assertIn(
            "ExecStart=/usr/bin/python3 -I "
            "/usr/local/sbin/uten-imp-existing-test-host-db-commissioner worker",
            unit,
        )
        self.assertIn("KillMode=control-group", unit)
        self.assertIn("SendSIGKILL=yes", unit)
        self.assertIn("Restart=no", unit)
        self.assertNotIn("[Install]", unit)

        preparer = (
            PROJECT_ROOT
            / "deploy/setup/prepare-existing-test-host-internal-runtime.py"
        ).read_text(encoding="utf-8")
        self.assertIn('"databaseCommissionerUnitSha256"', preparer)
        self.assertIn(
            '"/etc/systemd/system/uten-imp-internal-db-commissioner.service"',
            preparer,
        )

    def test_same_request_dispatcher_reentry_adopts_pid1_worker_completion(self):
        """Losing the external CLI does not kill a systemd-owned worker.

        A second dispatcher with the exact request waits for the same static
        unit and consumes its durable result without publishing a new grant.
        """

        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / "evidence"
            evidence.mkdir(mode=0o700)
            request_path = evidence / "worker-request.json"
            onboarding_path = Path(directory) / "onboarding.json"
            approval = "CHG-2026-0813-DISPATCH-REENTRY"
            request = fixed_worker_request(approval)
            write_json(request_path, request)

            updater = SimpleNamespace(
                DEFAULT_LOCK_FILE=Path("/fixed/operation.lock"),
                StateLock=lambda _path, **_kwargs: contextlib.nullcontext(),
                read_root_evidence_bytes=lambda path, **_kwargs: path.read_bytes(),
                assert_pre_database_runtime_contract=mock.Mock(),
            )
            bootstrap = {"databaseCommissionerUnitSha256": WORKER_UNIT_SHA256}
            calls: list[list[str]] = []

            def run(command: list[str], **_kwargs):
                calls.append(command)
                if command[1] == "start":
                    request_path.unlink()
                    write_json(
                        onboarding_path,
                        {
                            "approvalReference": approval,
                            "manifest": {"version": VERSION},
                        },
                    )
                return commissioner.subprocess.CompletedProcess(
                    command, 0, b"", b""
                )

            with mock.patch.object(
                commissioner.os, "geteuid", return_value=0
            ), mock.patch.object(
                commissioner, "EVIDENCE_BASE", evidence
            ), mock.patch.object(
                commissioner, "WORKER_REQUEST", request_path
            ), mock.patch.object(
                commissioner, "ONBOARDING_RECEIPT", onboarding_path
            ), mock.patch.object(
                commissioner, "require_root_directory"
            ), mock.patch.object(
                commissioner,
                "bootstrap_runtime_contract",
                return_value=(bootstrap, "e" * 64),
            ), mock.patch.object(
                commissioner, "load_modules", return_value=(updater, object())
            ), mock.patch.object(
                commissioner, "require_entry_closed"
            ), mock.patch.object(
                commissioner,
                "runtime_contract",
                return_value=(
                    {"databaseCommissionerUnitSha256": WORKER_UNIT_SHA256},
                    WORKER_RUNTIME_CONTRACT_SHA256,
                ),
            ), mock.patch.object(
                commissioner, "current_boot_id", return_value=WORKER_BOOT_ID
            ), mock.patch.object(
                commissioner, "verify_runtime_secret_binding"
            ), mock.patch.object(
                commissioner, "assert_fixed_worker_unit_pre_dispatch"
            ), mock.patch.object(
                commissioner, "atomic_json"
            ) as atomic_json, mock.patch.object(
                commissioner,
                "strict_json",
                side_effect=lambda path, _label: json.loads(
                    path.read_text(encoding="utf-8")
                ),
            ), mock.patch.object(
                commissioner, "run", side_effect=run
            ):
                result = commissioner.dispatch_worker(VERSION, approval)

            self.assertEqual(approval, result["approvalReference"])
            atomic_json.assert_not_called()
            self.assertEqual(
                [
                    [
                        "/usr/bin/systemctl",
                        "reset-failed",
                        commissioner.COMMISSIONER_UNIT,
                    ],
                    [
                        "/usr/bin/systemctl",
                        "start",
                        "--no-block",
                        commissioner.COMMISSIONER_UNIT,
                    ],
                ],
                calls,
            )

    def test_request_contract_rejects_tamper_and_dispatches_only_the_static_unit(self):
        request = fixed_worker_request("CHG-2026-0812-INTERNAL")
        commissioner.validate_worker_request(request)
        for label, changed in (
            ("unknown-key", {**request, "unexpected": True}),
            ("wrong-status", {**request, "status": "UNSUPERVISED"}),
            ("wrong-request-id", {**request, "requestId": "f" * 32}),
        ):
            with self.subTest(case=label), self.assertRaises(
                commissioner.CommissioningError
            ):
                commissioner.validate_worker_request(changed)

        with tempfile.TemporaryDirectory() as directory:
            evidence_base = Path(directory) / "evidence"
            evidence_base.mkdir()
            request_path = evidence_base / "worker-request.json"
            onboarding_path = Path(directory) / "onboarding.json"
            calls: list[tuple[list[str], dict[str, object]]] = []
            updater = SimpleNamespace(
                DEFAULT_LOCK_FILE=Path("/fixed/operation.lock"),
                StateLock=lambda _path, **_kwargs: contextlib.nullcontext(),
                assert_pre_database_runtime_contract=mock.Mock()
            )
            bootstrap = {"databaseCommissionerUnitSha256": WORKER_UNIT_SHA256}

            def atomic(path: Path, value: object, **_kwargs):
                write_json(path, value)

            def run(command: list[str], **kwargs):
                calls.append((command, kwargs))
                if command == [
                    "/usr/bin/systemctl",
                    "start",
                    "--no-block",
                    commissioner.COMMISSIONER_UNIT,
                ]:
                    self.assertTrue(request_path.is_file())
                    request_path.unlink()
                    write_json(
                        onboarding_path,
                        {
                            "approvalReference": "CHG-2026-0812-INTERNAL",
                            "manifest": {"version": VERSION},
                        },
                    )
                return commissioner.subprocess.CompletedProcess(
                    command, 0, b"", b""
                )

            with mock.patch.object(
                commissioner.os, "geteuid", return_value=0
            ), mock.patch.object(
                commissioner, "EVIDENCE_BASE", evidence_base
            ), mock.patch.object(
                commissioner, "WORKER_REQUEST", request_path
            ), mock.patch.object(
                commissioner, "ONBOARDING_RECEIPT", onboarding_path
            ), mock.patch.object(
                commissioner, "require_root_directory"
            ), mock.patch.object(
                commissioner, "bootstrap_runtime_contract", return_value=(bootstrap, "e" * 64)
            ), mock.patch.object(
                commissioner, "load_modules", return_value=(updater, object())
            ), mock.patch.object(
                commissioner, "require_entry_closed"
            ), mock.patch.object(
                commissioner,
                "runtime_contract",
                return_value=(
                    {"databaseCommissionerUnitSha256": WORKER_UNIT_SHA256},
                    WORKER_RUNTIME_CONTRACT_SHA256,
                ),
            ), mock.patch.object(
                commissioner, "current_boot_id", return_value=WORKER_BOOT_ID
            ), mock.patch.object(
                commissioner, "verify_runtime_secret_binding"
            ), mock.patch.object(
                commissioner, "assert_fixed_worker_unit_pre_dispatch"
            ), mock.patch.object(
                commissioner, "atomic_json", side_effect=atomic
            ), mock.patch.object(
                commissioner,
                "strict_json",
                side_effect=lambda path, _label: json.loads(
                    path.read_text(encoding="utf-8")
                ),
            ), mock.patch.object(
                commissioner, "run", side_effect=run
            ), mock.patch.object(
                commissioner,
                "systemd_state",
                side_effect=AssertionError(
                    "the fixed worker request was not consumed by the mocked PID 1 start"
                ),
            ):
                onboarding = commissioner.dispatch_worker(
                    VERSION, "CHG-2026-0812-INTERNAL"
                )

            self.assertEqual(VERSION, onboarding["manifest"]["version"])
            self.assertEqual(
                [
                    [
                        "/usr/bin/systemctl",
                        "reset-failed",
                        commissioner.COMMISSIONER_UNIT,
                    ],
                    [
                        "/usr/bin/systemctl",
                        "start",
                        "--no-block",
                        commissioner.COMMISSIONER_UNIT,
                    ],
                ],
                [command for command, _kwargs in calls],
            )
            self.assertEqual((0, 1), calls[0][1]["allowed"])
            self.assertEqual(30, calls[1][1]["timeout"])

    def test_every_dispatch_preflight_failure_precedes_request_and_systemd_start(self):
        stages = (
            "bootstrap_runtime_contract",
            "load_modules",
            "require_entry_closed",
            "runtime_contract",
            "assert_pre_database_runtime_contract",
            "verify_runtime_secret_binding",
            "assert_fixed_worker_unit_pre_dispatch",
        )
        for stage in stages:
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as directory:
                evidence = Path(directory) / "evidence"
                evidence.mkdir(mode=0o700)
                request_path = evidence / "worker-request.json"
                updater = SimpleNamespace(
                    assert_pre_database_runtime_contract=mock.Mock()
                )
                guard = object()
                bootstrap = {"databaseCommissionerUnitSha256": WORKER_UNIT_SHA256}
                failure = commissioner.CommissioningError(
                    f"injected pre-dispatch drift at {stage}"
                )
                atomic = mock.Mock()
                run = mock.Mock()
                with contextlib.ExitStack() as stack:
                    stack.enter_context(
                        mock.patch.object(
                            commissioner.os, "geteuid", return_value=0
                        )
                    )
                    stack.enter_context(
                        mock.patch.object(commissioner, "EVIDENCE_BASE", evidence)
                    )
                    stack.enter_context(
                        mock.patch.object(
                            commissioner, "WORKER_REQUEST", request_path
                        )
                    )
                    stack.enter_context(
                        mock.patch.object(commissioner, "require_root_directory")
                    )
                    preflights = {
                        "bootstrap_runtime_contract": stack.enter_context(
                            mock.patch.object(
                                commissioner,
                                "bootstrap_runtime_contract",
                                return_value=(bootstrap, "e" * 64),
                            )
                        ),
                        "load_modules": stack.enter_context(
                            mock.patch.object(
                                commissioner,
                                "load_modules",
                                return_value=(updater, guard),
                            )
                        ),
                        "require_entry_closed": stack.enter_context(
                            mock.patch.object(commissioner, "require_entry_closed")
                        ),
                        "runtime_contract": stack.enter_context(
                            mock.patch.object(
                                commissioner,
                                "runtime_contract",
                                return_value=(
                                    {
                                        "databaseCommissionerUnitSha256": (
                                            WORKER_UNIT_SHA256
                                        )
                                    },
                                    WORKER_RUNTIME_CONTRACT_SHA256,
                                ),
                            )
                        ),
                        "verify_runtime_secret_binding": stack.enter_context(
                            mock.patch.object(
                                commissioner, "verify_runtime_secret_binding"
                            )
                        ),
                        "assert_fixed_worker_unit_pre_dispatch": stack.enter_context(
                            mock.patch.object(
                                commissioner,
                                "assert_fixed_worker_unit_pre_dispatch",
                            )
                        ),
                    }
                    stack.enter_context(
                        mock.patch.object(commissioner, "atomic_json", atomic)
                    )
                    stack.enter_context(mock.patch.object(commissioner, "run", run))
                    if stage == "assert_pre_database_runtime_contract":
                        updater.assert_pre_database_runtime_contract.side_effect = failure
                    else:
                        preflights[stage].side_effect = failure
                    with self.assertRaisesRegex(
                        commissioner.CommissioningError, "pre-dispatch drift"
                    ):
                        commissioner.dispatch_worker(
                            VERSION, "CHG-2026-0812-PREDISPATCH"
                        )
                atomic.assert_not_called()
                run.assert_not_called()
                self.assertFalse(os.path.lexists(request_path))

    def test_finalizing_gate_precedes_worker_request_and_systemd_start(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / "evidence"
            evidence.mkdir(mode=0o700)
            request_path = evidence / "worker-request.json"

            class FinalizingStateLock:
                def __init__(self, _path: Path, **_kwargs):
                    pass

                def __enter__(self):
                    raise commissioner.CommissioningError(
                        "recovery ingress finalization is still owned"
                    )

                def __exit__(self, *_args):
                    return False

            updater = SimpleNamespace(
                DEFAULT_LOCK_FILE=Path("/fixed/operation.lock"),
                StateLock=FinalizingStateLock,
                assert_pre_database_runtime_contract=mock.Mock(),
            )
            bootstrap = {"databaseCommissionerUnitSha256": WORKER_UNIT_SHA256}
            atomic = mock.Mock()
            run = mock.Mock(
                side_effect=commissioner.CommissioningError(
                    "systemd start reached before finalizing gate"
                )
            )
            with mock.patch.object(
                commissioner.os, "geteuid", return_value=0
            ), mock.patch.object(
                commissioner, "EVIDENCE_BASE", evidence
            ), mock.patch.object(
                commissioner, "WORKER_REQUEST", request_path
            ), mock.patch.object(
                commissioner, "require_root_directory"
            ), mock.patch.object(
                commissioner,
                "bootstrap_runtime_contract",
                return_value=(bootstrap, "e" * 64),
            ), mock.patch.object(
                commissioner, "load_modules", return_value=(updater, object())
            ), mock.patch.object(
                commissioner, "require_entry_closed"
            ), mock.patch.object(
                commissioner,
                "runtime_contract",
                return_value=(
                    {"databaseCommissionerUnitSha256": WORKER_UNIT_SHA256},
                    WORKER_RUNTIME_CONTRACT_SHA256,
                ),
            ), mock.patch.object(
                commissioner, "current_boot_id", return_value=WORKER_BOOT_ID
            ), mock.patch.object(
                commissioner, "verify_runtime_secret_binding"
            ), mock.patch.object(
                commissioner, "assert_fixed_worker_unit_pre_dispatch"
            ), mock.patch.object(
                commissioner, "atomic_json", atomic
            ), mock.patch.object(
                commissioner, "run", run
            ), self.assertRaisesRegex(
                commissioner.CommissioningError,
                "finalization is still owned",
            ):
                commissioner.dispatch_worker(
                    VERSION, "CHG-2026-0813-FINALIZING"
                )

            atomic.assert_not_called()
            run.assert_not_called()
            self.assertFalse(os.path.lexists(request_path))

    def test_finalizing_gate_precedes_assessment_snapshot_and_cleanup(self):
        class FinalizingStateLock:
            def __init__(self, _path: Path, **_kwargs):
                pass

            def __enter__(self):
                raise commissioner.CommissioningError(
                    "recovery ingress finalization is still owned"
                )

            def __exit__(self, *_args):
                return False

        updater = SimpleNamespace(
            DEFAULT_LOCK_FILE=Path("/fixed/operation.lock"),
            StateLock=FinalizingStateLock,
            snapshot_candidate=mock.Mock(
                side_effect=commissioner.CommissioningError(
                    "snapshot reached before finalizing gate"
                )
            ),
        )
        guard = SimpleNamespace(verify_candidate=mock.Mock())
        with mock.patch.object(
            commissioner.os, "geteuid", return_value=0
        ), mock.patch.object(
            commissioner, "bootstrap_runtime_contract", return_value=({}, "e" * 64)
        ), mock.patch.object(
            commissioner, "load_modules", return_value=(updater, guard)
        ), mock.patch.object(
            commissioner, "require_root_directory"
        ), mock.patch.object(
            commissioner, "require_entry_closed"
        ), mock.patch.object(
            commissioner,
            "runtime_contract",
            return_value=({"deploymentProfile": "internal-test-local-v1"}, "1" * 64),
        ), mock.patch.object(
            commissioner,
            "storage_receipt",
            return_value=(Path("/fixed/storage-complete.json"), {}, "2" * 64),
        ), mock.patch.object(
            commissioner, "verify_live_storage", return_value={}
        ), mock.patch.object(
            commissioner, "verify_runtime_secret_binding"
        ), mock.patch.object(
            commissioner.os.path, "lexists", return_value=False
        ), mock.patch.object(
            commissioner, "pgdata_empty", return_value=True
        ), mock.patch.object(
            commissioner, "systemd_state", return_value="inactive"
        ), self.assertRaisesRegex(
            commissioner.CommissioningError, "finalization is still owned"
        ):
            commissioner.assess(VERSION)

        updater.snapshot_candidate.assert_not_called()
        guard.verify_candidate.assert_not_called()

    def test_effective_worker_unit_drift_is_zero_request_zero_start(self):
        expected_states = {
            "ActiveState": "inactive",
            "AmbientCapabilities": "",
            "DropInPaths": "",
            "ExecStart": "fixture encoded command",
            "FragmentPath": str(commissioner.COMMISSIONER_UNIT_FILE),
            "Group": "root",
            "KillMode": "control-group",
            "LoadState": "loaded",
            "OOMPolicy": "stop",
            "Restart": "no",
            "RuntimeDirectory": "uten-imp-internal-db-commissioner",
            "RuntimeDirectoryMode": "0700",
            "SendSIGKILL": "yes",
            "Type": "oneshot",
            "UnitFileState": "static",
            "User": "root",
        }
        drifts = {
            "unit-digest": None,
            "ActiveState": "active",
            "AmbientCapabilities": "CAP_SYS_ADMIN",
            "DropInPaths": "/etc/systemd/system/unsafe.conf",
            "FragmentPath": "/tmp/unsafe.service",
            "Group": "users",
            "KillMode": "process",
            "LoadState": "masked",
            "OOMPolicy": "continue",
            "Restart": "always",
            "RuntimeDirectory": "unbounded-worker",
            "RuntimeDirectoryMode": "0755",
            "SendSIGKILL": "no",
            "Type": "simple",
            "UnitFileState": "enabled",
            "User": "nobody",
            "ExecStart": "unexpected command",
        }
        for property_name, drifted in drifts.items():
            with self.subTest(property=property_name), tempfile.TemporaryDirectory() as directory:
                evidence = Path(directory) / "evidence"
                evidence.mkdir(mode=0o700)
                request_path = evidence / "worker-request.json"
                states = dict(expected_states)
                if property_name != "unit-digest":
                    states[property_name] = str(drifted)
                parsed_command = [
                    (
                        "/usr/bin/python3",
                        "/usr/bin/python3 -I "
                        "/usr/local/sbin/uten-imp-existing-test-host-db-commissioner worker",
                    )
                ]
                if property_name == "ExecStart":
                    parsed_command = [("/bin/sh", "/bin/sh -c unsafe")]
                updater = SimpleNamespace(
                    assert_pre_database_runtime_contract=mock.Mock(),
                    systemd_exec_commands=mock.Mock(return_value=parsed_command),
                )
                bootstrap = {"databaseCommissionerUnitSha256": WORKER_UNIT_SHA256}
                atomic = mock.Mock()
                run = mock.Mock()
                with mock.patch.object(
                    commissioner.os, "geteuid", return_value=0
                ), mock.patch.object(
                    commissioner, "EVIDENCE_BASE", evidence
                ), mock.patch.object(
                    commissioner, "WORKER_REQUEST", request_path
                ), mock.patch.object(
                    commissioner, "require_root_directory"
                ), mock.patch.object(
                    commissioner,
                    "bootstrap_runtime_contract",
                    return_value=(bootstrap, "e" * 64),
                ), mock.patch.object(
                    commissioner, "load_modules", return_value=(updater, object())
                ), mock.patch.object(
                    commissioner, "require_entry_closed"
                ), mock.patch.object(
                    commissioner,
                    "runtime_contract",
                    return_value=(
                        {"databaseCommissionerUnitSha256": WORKER_UNIT_SHA256},
                        WORKER_RUNTIME_CONTRACT_SHA256,
                    ),
                ), mock.patch.object(
                    commissioner, "verify_runtime_secret_binding"
                ), mock.patch.object(
                    commissioner, "require_root_file"
                ), mock.patch.object(
                    commissioner,
                    "sha256_file",
                    return_value=(
                        "e" * 64 if property_name == "unit-digest" else "d" * 64
                    ),
                ), mock.patch.object(
                    commissioner,
                    "systemd_state",
                    side_effect=lambda _unit, name: states[name],
                ), mock.patch.object(
                    commissioner, "atomic_json", atomic
                ), mock.patch.object(
                    commissioner, "run", run
                ), self.assertRaises(commissioner.CommissioningError):
                    commissioner.dispatch_worker(
                        VERSION, "CHG-2026-0812-UNIT-DRIFT"
                    )
                atomic.assert_not_called()
                run.assert_not_called()
                self.assertFalse(os.path.lexists(request_path))


class UpdaterVenvInventoryBridgeTest(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix", "venv ownership inventory is POSIX-only")
    def test_preparer_updater_and_boot_verifier_hash_the_same_exact_venv_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            updater_root = root / "updater"
            venv = updater_root / "venv"
            (venv / "bin").mkdir(parents=True)
            (venv / "lib/python3.12/site-packages/demo").mkdir(parents=True)
            (venv / "lib/python3.12/site-packages/demo/module.py").write_bytes(
                b"value = 1\n"
            )
            (venv / "pyvenv.cfg").write_bytes(b"include-system-site-packages = false\n")
            os.symlink("/usr/bin/python3", venv / "bin/python")

            verifier = updater_root / "wheelhouse_supply_chain.py"
            lock = updater_root / "requirements.lock"
            verifier.write_bytes(b"# fixture verifier\n")
            lock.write_bytes(b"demo==1 --hash=sha256:" + b"1" * 64 + b"\n")
            signers = root / "release-allowed-signers"
            signers.write_bytes(
                b"uten-imp-release ssh-ed25519 " + b"A" * 44 + b"\n"
            )
            oss_env = root / "oss.env"
            oss_env.write_bytes(b"fixture=1\n")
            updater_state = root / "state"
            updater_state.mkdir()
            operation_lock = root / "operation.lock"
            operation_lock.write_bytes(b"")

            successful = commissioner.subprocess.CompletedProcess(
                ["verify-installed"], 0, b"", b""
            )
            preparer_path = SETUP_DIR / "prepare-existing-test-host-internal-runtime.py"
            preparer = load_module(
                "internal_test_host_preparer_venv_bridge_under_test", preparer_path
            )
            real_lstat = type(venv).lstat

            class RootStatProxy:
                def __init__(self, details):
                    self.details = details

                def __getattr__(self, name):
                    if name == "st_uid":
                        return 0
                    return getattr(self.details, name)

            def root_python_lstat(path: Path, *args, **kwargs):
                details = real_lstat(path, *args, **kwargs)
                if path == venv / "bin/python":
                    return RootStatProxy(details)
                return details

            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(preparer, "UPDATER_ROOT", updater_root))
                stack.enter_context(
                    mock.patch.object(preparer, "UPDATER_VENV_PYTHON", venv / "bin/python")
                )
                stack.enter_context(
                    mock.patch.object(
                        preparer,
                        "SOURCES",
                        {
                            "wheelhouseSupplyChainSha256": verifier,
                            "updaterRequirementsLockSha256": lock,
                        },
                    )
                )
                stack.enter_context(
                    mock.patch.object(preparer, "UPDATER_ALLOWED_SIGNERS", signers)
                )
                stack.enter_context(
                    mock.patch.object(preparer, "STABLE_ALLOWED_SIGNERS", signers)
                )
                stack.enter_context(mock.patch.object(preparer, "UPDATER_OSS_ENV", oss_env))
                stack.enter_context(mock.patch.object(preparer, "UPDATER_STATE", updater_state))
                stack.enter_context(mock.patch.object(preparer, "OPERATION_LOCK", operation_lock))
                stack.enter_context(
                    mock.patch.object(
                        preparer,
                        "_updater_identity",
                        return_value=(os.getuid(), os.getgid()),
                    )
                )
                stack.enter_context(mock.patch.object(preparer, "root_directory"))
                stack.enter_context(mock.patch.object(preparer, "root_file"))
                stack.enter_context(mock.patch.object(preparer, "_exact_owned_path"))
                stack.enter_context(mock.patch.object(preparer.os, "access", return_value=True))
                stack.enter_context(mock.patch.object(preparer, "run", return_value=successful))
                stack.enter_context(
                    mock.patch.object(
                        type(venv),
                        "lstat",
                        autospec=True,
                        side_effect=root_python_lstat,
                    )
                )
                producer = preparer.validate_common_updater_prerequisites()[
                    "updaterVenvInventorySha256"
                ]

            def remap(path_value: object) -> Path:
                text = str(path_value)
                mapping = {
                    "/opt/uten-imp/updater/wheelhouse_supply_chain.py": verifier,
                    "/opt/uten-imp/updater/requirements.lock": lock,
                    "/opt/uten-imp/updater/venv": venv,
                }
                return mapping.get(text, Path(text))

            completed = commissioner.subprocess.CompletedProcess(
                ["verify-installed"], 0, b"", b""
            )
            reviewed_wheelhouse_source = (
                UPDATER_DIR / "wheelhouse_supply_chain.py"
            ).read_bytes()
            with mock.patch.object(
                release_updater, "Path", side_effect=remap
            ), mock.patch.object(
                release_updater, "require_root_controlled_file"
            ), mock.patch.object(
                release_updater,
                "read_root_controlled_bytes",
                return_value=reviewed_wheelhouse_source,
            ), mock.patch.object(
                release_updater.subprocess, "run", return_value=completed
            ) as updater_verify, mock.patch.object(
                type(venv),
                "lstat",
                autospec=True,
                side_effect=root_python_lstat,
            ):
                updater_digest = release_updater.updater_venv_inventory_sha256()
            with mock.patch.object(
                runtime_boot, "Path", side_effect=remap
            ), mock.patch.object(
                runtime_boot, "_require_root_file"
            ), mock.patch.object(
                runtime_boot.subprocess, "run", return_value=completed
            ) as boot_verify, mock.patch.object(
                type(venv),
                "lstat",
                autospec=True,
                side_effect=root_python_lstat,
            ):
                boot_digest = runtime_boot._updater_venv_inventory_sha256()

            self.assertEqual(producer, updater_digest)
            self.assertEqual(producer, boot_digest)
            for invoked in (updater_verify, boot_verify):
                kwargs = invoked.call_args.kwargs
                self.assertEqual(60, kwargs["timeout"])
                self.assertEqual(
                    {
                        "LANG": "C.UTF-8",
                        "LC_ALL": "C.UTF-8",
                        "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
                    },
                    kwargs["env"],
                )

            original = producer
            (venv / "lib/python3.12/site-packages/demo/module.py").write_bytes(
                b"value = 2\n"
            )
            with mock.patch.object(
                release_updater, "Path", side_effect=remap
            ), mock.patch.object(
                release_updater, "require_root_controlled_file"
            ), mock.patch.object(
                release_updater,
                "read_root_controlled_bytes",
                return_value=reviewed_wheelhouse_source,
            ), mock.patch.object(
                release_updater.subprocess, "run", return_value=completed
            ), mock.patch.object(
                type(venv),
                "lstat",
                autospec=True,
                side_effect=root_python_lstat,
            ):
                changed = release_updater.updater_venv_inventory_sha256()
            self.assertNotEqual(original, changed)


class PinnedHelperDigestContractTest(unittest.TestCase):
    def test_every_runtime_pinned_digest_matches_the_reviewed_source_bytes(self):
        release_pins = {
            "DATABASE_RECOVERY_VERIFIER_SHA256": (
                PROJECT_ROOT / "deploy/updater/database_recovery_verifier.py"
            ),
            "RUNTIME_BOOT_VERIFIER_SHA256": (
                PROJECT_ROOT / "deploy/updater/runtime_boot_verifier.py"
            ),
            "STORAGE_BOOT_VERIFIER_SHA256": (
                PROJECT_ROOT / "deploy/updater/storage_boot_verifier.py"
            ),
            "STORAGE_MOUNT_OBSERVER_SHA256": (
                PROJECT_ROOT / "deploy/updater/storage_mount_observer.py"
            ),
            "MIGRATION_AUTHORIZATION_HELPER_SHA256": (
                PROJECT_ROOT / "deploy/updater/migration_authorization.py"
            ),
            "ENTRY_WATCHDOG_UNIT_SHA256": (
                PROJECT_ROOT
                / "deploy/systemd/uten-imp-entry-watchdog.service.example"
            ),
            "ENTRY_WATCHDOG_SCRIPT_SHA256": (
                PROJECT_ROOT / "deploy/watchdog/uten-imp-entry-watchdog.sh"
            ),
        }
        for constant, source in release_pins.items():
            with self.subTest(owner="release-updater", constant=constant):
                self.assertEqual(
                    hashlib.sha256(source.read_bytes()).hexdigest(),
                    getattr(release_updater, constant),
                )

        boot_pins = {
            "RELEASE_GUARD_SHA256": PROJECT_ROOT / "deploy/updater/release_guard.py",
            "DATABASE_VERIFIER_SHA256": (
                PROJECT_ROOT / "deploy/updater/database_recovery_verifier.py"
            ),
            "STORAGE_VERIFIER_SHA256": (
                PROJECT_ROOT / "deploy/updater/storage_boot_verifier.py"
            ),
        }
        for constant, source in boot_pins.items():
            with self.subTest(owner="runtime-boot", constant=constant):
                self.assertEqual(
                    hashlib.sha256(source.read_bytes()).hexdigest(),
                    getattr(runtime_boot, constant),
                )


class MigratorEnvironmentAndPreflightTest(unittest.TestCase):
    class Lock:
        def __init__(self, *_args, **_kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

    def test_migrator_receives_only_the_narrow_password_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / TRANSACTION_ID
            evidence.mkdir()
            payload = root / "payload"
            jar = payload / "server/uten-imp-migrator.jar"
            jar.parent.mkdir(parents=True)
            jar.write_bytes(b"signed migrator bytes")
            worker_runtime = root / "worker-runtime"
            worker_runtime.mkdir()
            execution = root / "execution"
            password = "S" * 32
            calls: list[tuple[list[str], dict[str, object]]] = []

            def fake_mkdtemp(**kwargs):
                self.assertEqual("migrator-", kwargs["prefix"])
                self.assertEqual(str(worker_runtime), kwargs["dir"])
                execution.mkdir()
                return str(execution)

            def fake_run(command: list[str], **kwargs):
                calls.append((command, kwargs))
                return commissioner.subprocess.CompletedProcess(
                    command,
                    0,
                    b"UTEN_MIGRATION_VALIDATE_OK\n"
                    b"UTEN_MIGRATION_OK migrations_executed=255\n",
                    b"",
                )

            receipts: list[dict[str, object]] = []
            with mock.patch.object(commissioner, "require_root_file"), mock.patch.object(
                commissioner, "require_root_directory"
            ), mock.patch.object(
                commissioner, "WORKER_RUNTIME", worker_runtime
            ), mock.patch.object(
                commissioner.pwd,
                "getpwnam",
                return_value=SimpleNamespace(
                    pw_gid=getattr(os, "getgid", lambda: 0)()
                ),
            ), mock.patch.object(
                commissioner.tempfile, "mkdtemp", side_effect=fake_mkdtemp
            ), mock.patch.object(
                commissioner.os, "chown"
            ), mock.patch.object(
                commissioner, "secret_value", return_value=password
            ), mock.patch.object(
                commissioner, "run", side_effect=fake_run
            ), mock.patch.object(
                commissioner,
                "atomic_json",
                side_effect=lambda _path, value, **_kwargs: receipts.append(value),
            ):
                commissioner.run_migrator(
                    evidence,
                    payload,
                    {"migratorJarSha256": commissioner.sha256_file(jar)},
                )

            self.assertEqual(1, len(calls))
            command, kwargs = calls[0]
            self.assertEqual(
                [
                    "/usr/sbin/runuser",
                    "-u",
                    "uten-imp-migrate",
                    "--",
                    "/usr/bin/java",
                    "-Xms64m",
                    "-Xmx512m",
                    "-XX:+ExitOnOutOfMemoryError",
                    "-jar",
                    str(execution / "uten-imp-migrator.jar"),
                ],
                command,
            )
            self.assertEqual(1800, kwargs["timeout"])
            self.assertNotIn("input_bytes", kwargs)
            self.assertEqual(
                {
                    "LANG": "C.UTF-8",
                    "LC_ALL": "C.UTF-8",
                    "PATH": "/usr/bin:/bin",
                    "UTEN_MIGRATOR_DB_PASSWORD": password,
                },
                kwargs["environment"],
            )
            self.assertNotIn(password, " ".join(command))
            self.assertNotIn(password, json.dumps(receipts, sort_keys=True))
            self.assertEqual("MIGRATION_PROCESS_SUCCEEDED", receipts[0]["status"])

    def test_pre_database_runtime_validator_runs_before_storage_or_onboarding_reads(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            onboarding_path = root / "onboarding.json"
            onboarding_path.write_bytes(b"{}")
            order: list[str] = []
            receipt = {
                "approvalReference": "CHG-2026-0812-DIFFERENT",
                "manifest": {"version": VERSION},
                "runtimeContractSha256": "a" * 64,
                "storageCommissioningReceiptSha256": "b" * 64,
            }

            def record(name: str, value=None):
                order.append(name)
                return value

            updater = SimpleNamespace(
                StateLock=self.Lock,
                DatabaseMaintenanceLock=self.Lock,
                DEFAULT_LOCK_FILE=root / "operation.lock",
                assert_pre_database_runtime_contract=lambda: record("pre-db"),
                validate_internal_test_onboarding_receipt=lambda _value, **_kwargs: record(
                    "validate-onboarding"
                ),
            )
            with mock.patch.object(commissioner.os, "geteuid", return_value=0), mock.patch.object(
                commissioner, "ONBOARDING_RECEIPT", onboarding_path
            ), mock.patch.object(
                commissioner,
                "bootstrap_runtime_contract",
                return_value=({}, "0" * 64),
            ), mock.patch.object(
                commissioner, "load_modules", return_value=(updater, object())
            ), mock.patch.object(
                commissioner,
                "require_entry_closed",
                side_effect=lambda: record("entry-closed"),
            ), mock.patch.object(
                commissioner,
                "verify_runtime_secret_binding",
                side_effect=lambda: record("secret-binding"),
            ), mock.patch.object(
                commissioner,
                "runtime_contract",
                side_effect=lambda *_args: record(
                    "runtime-contract", ({}, "a" * 64)
                ),
            ), mock.patch.object(
                commissioner, "validate_worker_request_live"
            ), mock.patch.object(
                commissioner,
                "storage_receipt",
                side_effect=lambda: record(
                    "storage-receipt", (root / "storage.json", {}, "b" * 64)
                ),
            ), mock.patch.object(
                commissioner,
                "validate_storage_terminal_contract",
                side_effect=lambda *_args: record("storage-terminal"),
            ), mock.patch.object(
                commissioner,
                "verify_live_storage",
                side_effect=lambda *_args: record("live-storage", {}),
            ), mock.patch.object(
                commissioner,
                "strict_json",
                side_effect=lambda *_args: record("onboarding-read", receipt),
            ):
                with self.assertRaisesRegex(
                    commissioner.CommissioningError,
                    "existing onboarding receipt differs",
                ):
                    commissioner.apply(
                        VERSION,
                        "CHG-2026-0812-INTERNAL",
                        worker_request_sha256="f" * 64,
                        worker_request={},
                    )

            self.assertLess(order.index("entry-closed"), order.index("pre-db"))
            self.assertLess(order.index("pre-db"), order.index("secret-binding"))
            self.assertLess(
                order.index("secret-binding"), order.index("storage-receipt")
            )
            self.assertLess(order.index("pre-db"), order.index("storage-receipt"))
            self.assertLess(order.index("pre-db"), order.index("live-storage"))
            self.assertLess(order.index("pre-db"), order.index("onboarding-read"))
            self.assertLess(
                order.index("onboarding-read"), order.index("validate-onboarding")
            )


class DatabaseTerminalCrashBoundaryTest(unittest.TestCase):
    class Lock:
        def __init__(self, *_args, **_kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.base = self.root / "database-commissioning"
        self.evidence = self.base / TRANSACTION_ID
        self.build = self.evidence / "candidate-build-1"
        self.metadata = self.build / "candidate-metadata"
        self.payload = self.build / "payload" / VERSION
        self.metadata.mkdir(parents=True)
        self.payload.mkdir(parents=True)
        write_json(self.metadata / "manifest.json", {"version": VERSION})
        self.plan_path = self.evidence / "transaction-manifest.json"
        self.approval = "CHG-2026-0812-INTERNAL"
        self.contract_sha = "a" * 64
        self.storage_sha = "b" * 64
        self.plan = {
            "approvalReference": self.approval,
            "candidateMetadataPath": str(self.metadata),
            "candidatePayloadPath": str(self.payload),
            "createdAtUtc": "2026-08-12T12:00:00Z",
            "expiresAtUtc": "2026-08-19T12:00:00Z",
            "manifest": {"version": VERSION},
            "runtimeContractSha256": self.contract_sha,
            "storageCommissioningReceiptSha256": self.storage_sha,
            "transactionId": TRANSACTION_ID,
        }
        write_json(self.plan_path, self.plan)
        self.plan_sha = commissioner.sha256_file(self.plan_path)
        self.preactive = {
            "approvalReference": self.approval,
            "createdAtUtc": "2026-08-12T12:00:00Z",
            "evidencePath": str(self.evidence),
            "runtimeContractSha256": self.contract_sha,
            "schemaVersion": 1,
            "status": "PREPARING_ENTRY_CLOSED",
            "storageCommissioningReceiptSha256": self.storage_sha,
            "transactionId": TRANSACTION_ID,
            "version": VERSION,
        }
        self.preactive_archive = (
            self.evidence / commissioner.PREACTIVE_ARCHIVE_NAME
        )
        write_json(self.preactive_archive, self.preactive)
        write_json(
            self.evidence / commissioner.COMMISSIONING_AUTHORITY_NAME,
            {
                "approvalReference": self.approval,
                "authorizedAtUtc": "2026-08-12T12:01:00Z",
                "evidencePath": str(self.evidence),
                "kind": "uten-imp-internal-test-database-commissioning-authority",
                "planPath": str(self.plan_path),
                "planSha256": self.plan_sha,
                "preActiveSha256": commissioner.sha256_file(
                    self.preactive_archive
                ),
                "runtimeContractSha256": self.contract_sha,
                "schemaVersion": 1,
                "status": "AUTHORIZED_ENTRY_CLOSED",
                "storageCommissioningReceiptSha256": self.storage_sha,
                "transactionId": TRANSACTION_ID,
                "version": VERSION,
            },
        )
        self.identity = {
            "canonicalHistorySha256": "c" * 64,
            "headVersion": 255,
            "roleAclContractSha256": "d" * 64,
            "signedProjectionSha256": "e" * 64,
            "successfulMigrationCount": 255,
            "systemIdentifier": "123456789",
            "timeline": 1,
        }
        self.onboarding_path = self.root / "internal-test-onboarding.json"
        self.onboarding = {
            "approvalReference": self.approval,
            "commissioningAuthorityPath": str(
                self.evidence / commissioner.COMMISSIONING_AUTHORITY_NAME
            ),
            "commissioningAuthoritySha256": commissioner.sha256_file(
                self.evidence / commissioner.COMMISSIONING_AUTHORITY_NAME
            ),
            "commissioningAuthorizedAtUtc": "2026-08-12T12:01:00Z",
            "commissioningPlanExpiresAtUtc": self.plan["expiresAtUtc"],
            "commissioningPreActivePath": str(self.preactive_archive),
            "commissioningPreActiveSha256": commissioner.sha256_file(
                self.preactive_archive
            ),
            "completedAtUtc": "2026-08-12T12:10:00Z",
            "databaseIdentity": self.identity,
            "evidencePath": str(self.evidence),
            "expiresAtUtc": "2026-08-19T12:10:00Z",
            "manifest": {"version": VERSION},
            "runtimeContractSha256": self.contract_sha,
            "storageCommissioningReceiptSha256": self.storage_sha,
            "transactionId": TRANSACTION_ID,
            "transactionManifestPath": str(self.plan_path),
            "transactionManifestSha256": self.plan_sha,
        }
        write_json(self.onboarding_path, self.onboarding)
        self.active_path = self.base / "active.json"
        self.preactive_path = self.base / "pre-active.json"
        self.pointer = {
            "evidencePath": str(self.evidence),
            "planSha256": self.plan_sha,
            "schemaVersion": 1,
            "transactionId": TRANSACTION_ID,
        }
        self.storage_path = self.root / "nvme" / "complete.json"
        write_json(self.storage_path, {"fixture": "storage"})
        self.storage_observation = {
            "authoritySha256": "f" * 64,
            "filesystemUuid": "11111111-1111-4111-8111-111111111111",
        }
        write_json(self.root / "storage-authority.json", {"fixture": "authority"})

    def tearDown(self):
        self.temporary.cleanup()

    def complete_value(self) -> dict[str, object]:
        return {
            "completedAtUtc": "2026-08-12T12:10:00Z",
            "entryEnabled": False,
            "kind": "uten-imp-internal-test-database-commissioning-receipt",
            "onboardingReceiptSha256": commissioner.sha256_file(
                self.onboarding_path
            ),
            "productionAuthority": False,
            "schemaVersion": 1,
            "status": "COMMITTED_AWAITING_FIRST_ACTIVATION",
            "transactionId": TRANSACTION_ID,
        }

    def invoke(self):
        def atomic_json(path: Path, value: object, **_kwargs):
            write_json(path, value)

        storage_sequence = 0

        def write_storage(evidence: Path, phase: str, value: dict[str, object]):
            nonlocal storage_sequence
            storage_sequence += 1
            path = evidence / f"storage-{phase}-fixture-{storage_sequence}.json"
            raw = write_json(path, value)
            return path, hashlib.sha256(raw).hexdigest()

        updater = SimpleNamespace(
            StateLock=self.Lock,
            DatabaseMaintenanceLock=self.Lock,
            DEFAULT_LOCK_FILE=self.root / "operation.lock",
            assert_pre_database_runtime_contract=lambda: None,
            validate_internal_test_onboarding_receipt=lambda _value, **_kwargs: VERSION,
            verify_candidate_metadata=lambda _metadata, _signers: (
                "candidate",
                {"version": VERSION},
                self.payload,
            ),
        )
        guard = SimpleNamespace(verify_payload=lambda *_args, **_kwargs: None)
        patches = (
            mock.patch.object(commissioner.os, "geteuid", return_value=0),
            mock.patch.object(
                commissioner, "ONBOARDING_RECEIPT", self.onboarding_path
            ),
            mock.patch.object(commissioner, "EVIDENCE_BASE", self.base),
            mock.patch.object(commissioner, "ACTIVE_POINTER", self.active_path),
            mock.patch.object(
                commissioner, "PREACTIVE_POINTER", self.preactive_path
            ),
            mock.patch.object(
                commissioner,
                "bootstrap_runtime_contract",
                return_value=({}, "0" * 64),
            ),
            mock.patch.object(
                commissioner, "load_modules", return_value=(updater, guard)
            ),
            mock.patch.object(commissioner, "require_entry_closed"),
            mock.patch.object(commissioner, "verify_runtime_secret_binding"),
            mock.patch.object(commissioner, "validate_worker_request_live"),
            mock.patch.object(
                commissioner,
                "runtime_contract",
                return_value=(
                    {"deploymentProfile": "internal-test-local-v1"},
                    self.contract_sha,
                ),
            ),
            mock.patch.object(
                commissioner,
                "storage_receipt",
                return_value=(
                    self.storage_path,
                    {
                        "filesystemUuid": self.storage_observation[
                            "filesystemUuid"
                        ]
                    },
                    self.storage_sha,
                ),
            ),
            mock.patch.object(
                commissioner, "validate_storage_terminal_contract"
            ),
            mock.patch.object(
                commissioner,
                "verify_live_storage",
                return_value=self.storage_observation,
            ),
            mock.patch.object(commissioner, "require_root_directory"),
            mock.patch.object(commissioner, "require_root_file"),
            mock.patch.object(
                commissioner,
                "strict_json",
                side_effect=lambda path, _label: json.loads(
                    path.read_text(encoding="utf-8")
                ),
            ),
            mock.patch.object(commissioner, "fsync_directory"),
            mock.patch.object(
                commissioner, "manifest_binding", return_value={"version": VERSION}
            ),
            mock.patch.object(commissioner, "validate_transaction_plan"),
            mock.patch.object(commissioner, "require_fresh_plan"),
            mock.patch.object(
                commissioner,
                "validate_storage_observation_binding",
                return_value=self.storage_observation,
            ),
            mock.patch.object(
                commissioner,
                "write_storage_observation",
                side_effect=write_storage,
            ),
            mock.patch.object(commissioner, "initialize_cluster"),
            mock.patch.object(commissioner, "start_postgres"),
            mock.patch.object(commissioner, "configure_roles"),
            mock.patch.object(commissioner, "run_migrator"),
            mock.patch.object(
                commissioner, "database_identity", return_value=self.identity
            ),
            mock.patch.object(commissioner, "commit_postgres_boot_contract"),
            mock.patch.object(
                commissioner, "atomic_json", side_effect=atomic_json
            ),
            mock.patch.object(
                commissioner, "commissioner_sha256", return_value="9" * 64
            ),
            mock.patch.object(
                commissioner,
                "STORAGE_AUTHORITY",
                self.root / "storage-authority.json",
            ),
        )
        with contextlib.ExitStack() as stack:
            for active_patch in patches:
                stack.enter_context(active_patch)
            return commissioner.apply(
                VERSION,
                self.approval,
                worker_request_sha256="f" * 64,
                worker_request={},
            )

    def assert_terminal(self, original_onboarding: bytes):
        archive = self.evidence / "active-pointer.committed.json"
        self.assertFalse(self.active_path.exists())
        self.assertTrue(archive.is_file())
        self.assertEqual(self.pointer, json.loads(archive.read_text(encoding="utf-8")))
        self.assertTrue((self.evidence / "complete.json").is_file())
        self.assertEqual(original_onboarding, self.onboarding_path.read_bytes())

    def test_reenters_after_onboarding_publish_before_complete(self):
        write_json(self.active_path, self.pointer)
        original = self.onboarding_path.read_bytes()
        result = self.invoke()
        self.assertEqual(self.onboarding, result)
        self.assert_terminal(original)

    def test_reenters_after_complete_publish_before_pointer_rename(self):
        write_json(self.active_path, self.pointer)
        write_json(self.evidence / "complete.json", self.complete_value())
        original = self.onboarding_path.read_bytes()
        result = self.invoke()
        self.assertEqual(self.onboarding, result)
        self.assert_terminal(original)

    def test_reenters_after_pointer_rename_before_success_return(self):
        write_json(
            self.evidence / "active-pointer.committed.json", self.pointer
        )
        write_json(self.evidence / "complete.json", self.complete_value())
        original = self.onboarding_path.read_bytes()
        result = self.invoke()
        self.assertEqual(self.onboarding, result)
        self.assert_terminal(original)


class UpdaterDatabaseTerminalAdmissionTest(unittest.TestCase):
    def onboarding(self) -> dict[str, object]:
        evidence = (
            "/var/lib/uten-imp-internal-test-commissioning/" + TRANSACTION_ID
        )
        storage_evidence = (
            "/var/lib/uten-imp-nvme-commissioning/"
            "nvme-20260812T000000Z-0123456789ab"
        )
        return {
            "approvalReference": "CHG-2026-0812-INTERNAL",
            "backupEnabled": False,
            "commissionerSha256": "1" * 64,
            "commissioningAuthorityPath": evidence + "/commissioning-authorized.json",
            "commissioningAuthoritySha256": "9" * 64,
            "commissioningAuthorizedAtUtc": "2026-08-12T12:01:00Z",
            "commissioningPlanExpiresAtUtc": "2026-08-19T12:00:00Z",
            "commissioningPreActivePath": evidence + "/pre-active.committed.json",
            "commissioningPreActiveSha256": "a" * 64,
            "completedAtUtc": "2026-08-12T12:10:00Z",
            "currentPublished": False,
            "dataClassification": "discardable-test-only",
            "databaseIdentity": {},
            "deploymentProfile": "internal-test",
            "emptySourceProofPath": evidence + "/empty-source-proof.json",
            "emptySourceProofSha256": "2" * 64,
            "entryEnabled": False,
            "evidencePath": evidence,
            "expiresAtUtc": "2026-08-19T12:10:00Z",
            "kind": "uten-imp-internal-test-onboarding",
            "manifest": {},
            "migrationTerminalReceiptPath": evidence + "/migration-terminal.json",
            "migrationTerminalReceiptSha256": "3" * 64,
            "productionAuthority": False,
            "remainingNoGo": [
                "authoritative-data",
                "backup-restore",
                "business-uat",
            ],
            "runtimeContractSha256": "4" * 64,
            "schemaVersion": 1,
            "status": "COMMITTED_DATABASE_MIGRATED_ENTRY_CLOSED",
            "storageAuthoritySha256": "5" * 64,
            "storageCommissioningEvidencePath": storage_evidence,
            "storageCommissioningReceiptPath": storage_evidence + "/complete.json",
            "storageCommissioningReceiptSha256": "6" * 64,
            "storageObservationPath": evidence + "/storage-before-terminal-fixture-1.json",
            "storageObservationSha256": "7" * 64,
            "transactionManifestPath": evidence + "/transaction-manifest.json",
            "transactionManifestSha256": "8" * 64,
            "transactionId": TRANSACTION_ID,
        }

    def assert_live_pointer_refused(
        self,
        pointer_name: str,
        *,
        adoption_prepared_at_utc: str | None = None,
    ):
        terminal_storage = mock.Mock(
            side_effect=AssertionError(
                "terminal evidence must not be read while a live pointer exists"
            )
        )

        def lexists(path: object) -> bool:
            return Path(path).name == pointer_name

        with mock.patch.object(
            release_updater.os.path, "lexists", side_effect=lexists
        ), mock.patch.object(
            release_updater,
            "validate_internal_test_storage_observation",
            terminal_storage,
        ):
            with self.assertRaisesRegex(
                release_updater.UpdaterError, "not terminal"
            ):
                release_updater.validate_internal_test_onboarding_receipt(
                    self.onboarding(),
                    adoption_prepared_at_utc=adoption_prepared_at_utc,
                )
        terminal_storage.assert_not_called()

    def test_first_activation_refuses_onboarding_only_with_live_active_pointer(self):
        self.assert_live_pointer_refused("active.json")

    def test_first_activation_refuses_preactive_transaction_before_plan_commit(self):
        self.assert_live_pointer_refused("pre-active.json")

    def test_expired_first_activation_refuses_before_terminal_evidence(self):
        class LateDateTime(datetime):
            @classmethod
            def now(cls, tz=None):
                value = datetime(2026, 8, 20, 12, 0, tzinfo=timezone.utc)
                return value if tz is None else value.astimezone(tz)

        lexists = mock.Mock(
            side_effect=AssertionError(
                "expired onboarding must fail before reading live evidence"
            )
        )
        with mock.patch.object(
            release_updater, "datetime", LateDateTime
        ), mock.patch.object(
            release_updater.os.path, "lexists", lexists
        ), self.assertRaisesRegex(
            release_updater.UpdaterError, "expired before first activation"
        ):
            release_updater.validate_internal_test_onboarding_receipt(
                self.onboarding()
            )
        lexists.assert_not_called()

    def test_preexpiry_adoption_allows_late_resume_to_reach_terminal_gate(self):
        class LateDateTime(datetime):
            @classmethod
            def now(cls, tz=None):
                value = datetime(2026, 9, 20, 12, 0, tzinfo=timezone.utc)
                return value if tz is None else value.astimezone(tz)

        with mock.patch.object(release_updater, "datetime", LateDateTime):
            self.assert_live_pointer_refused(
                "active.json",
                adoption_prepared_at_utc="2026-08-13T12:00:00Z",
            )

    def test_forged_late_adoption_is_rejected_before_terminal_evidence(self):
        lexists = mock.Mock(
            side_effect=AssertionError(
                "late adoption must fail before reading live evidence"
            )
        )
        with mock.patch.object(
            release_updater.os.path, "lexists", lexists
        ), self.assertRaisesRegex(
            release_updater.UpdaterError,
            "not adopted inside its validity window",
        ):
            release_updater.validate_internal_test_onboarding_receipt(
                self.onboarding(),
                adoption_prepared_at_utc="2026-08-19T12:10:01Z",
            )
        lexists.assert_not_called()

    def test_authenticated_candidate_projection_binds_every_onboarding_field(self):
        candidate = {
            "commitSha": "a" * 40,
            "executableSha256s": {
                "server/uten-imp-migrator.jar": "1" * 64,
                "server/uten-imp-server.jar": "2" * 64,
            },
            "flywayMigrations": [
                {
                    "file": "V1__fixture.sql",
                    "flywayChecksum": 123,
                    "version": "1",
                }
            ],
            "flywayHeadVersion": "1",
            "flywayMigrationSetSha256": "3" * 64,
            "releaseSequence": 20260812001,
            "signingKeyId": "SHA256:" + "A" * 43,
            "version": VERSION,
        }
        manifest_sha = "4" * 64
        authority = release_updater.internal_test_candidate_manifest_binding(
            candidate, manifest_sha
        )
        self.assertEqual(VERSION, authority["version"])
        self.assertEqual(candidate["commitSha"], authority["commitSha"])
        self.assertEqual(
            candidate["signingKeyId"], authority["signingKeyId"]
        )
        self.assertEqual(manifest_sha, authority["manifestSha256"])
        self.assertEqual(
            candidate["executableSha256s"]["server/uten-imp-server.jar"],
            authority["serverJarSha256"],
        )
        self.assertEqual(
            candidate["executableSha256s"]["server/uten-imp-migrator.jar"],
            authority["migratorJarSha256"],
        )

        for case, mutate in (
            ("commit", lambda value: value.update(commitSha="b" * 40)),
            (
                "signing-key",
                lambda value: value.update(signingKeyId="SHA256:" + "B" * 43),
            ),
            (
                "server-jar",
                lambda value: value["executableSha256s"].update(
                    {"server/uten-imp-server.jar": "5" * 64}
                ),
            ),
            (
                "migrator-jar",
                lambda value: value["executableSha256s"].update(
                    {"server/uten-imp-migrator.jar": "6" * 64}
                ),
            ),
            (
                "flyway",
                lambda value: value.update(flywayMigrationSetSha256="7" * 64),
            ),
        ):
            with self.subTest(case=case):
                changed = json.loads(json.dumps(candidate))
                mutate(changed)
                self.assertNotEqual(
                    authority,
                    release_updater.internal_test_candidate_manifest_binding(
                        changed, manifest_sha
                    ),
                )


class RecoveryIngressProbeAuthorizationTest(unittest.TestCase):
    BOOT_ID = "880d0b3d-37a1-4448-bb51-c27d34820163"

    class RootLockStat:
        def __init__(self, details, gid: int):
            self._details = details
            self.st_mode = stat.S_IFREG | 0o660
            self.st_uid = 0
            self.st_gid = gid
            self.st_nlink = 1

        def __getattr__(self, name):
            return getattr(self._details, name)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "release"
        self.evidence = self.root / "recovery-evidence"
        self.transaction = self.evidence / ("5" * 16 + "-probe-fixture")
        self.transaction.mkdir(parents=True)
        self.pending_path = self.root / "recovery-ingress-pending.json"
        self.authorization_path = (
            self.root / "recovery-ingress-authorization.json"
        )
        self.lock_path = self.root / "operation.lock"
        self.lock_path.write_bytes(b"")
        self.lock_path.chmod(0o660)
        self.boot_id_path = self.root / "boot-id"
        self.boot_id_path.write_text(self.BOOT_ID + "\n", encoding="ascii")

    def tearDown(self):
        self.temporary.cleanup()

    def write_pending(self) -> bytes:
        return write_json(
            self.pending_path,
            {
                "action": "finish-activation",
                "commitSha256": "1" * 64,
                "markerSha256": "2" * 64,
                "planSha256": "5" * 64,
                "schemaVersion": 1,
                "status": "RECOVERY_COMMITTED_PENDING_INGRESS",
                "targetVersion": VERSION,
                "transactionDirectory": str(self.transaction),
            },
        )

    def write_authorization(self, pending_raw: bytes, **overrides) -> dict[str, object]:
        value = {
            "bootId": self.BOOT_ID,
            "issuerCommandLineSha256": "a" * 64,
            "issuerExecutablePath": "/usr/bin/python3.14",
            "issuerExecutableSha256": "b" * 64,
            "issuerPid": 4242,
            "issuerStartTimeTicks": 123456,
            "issuedAtUtc": datetime.now(timezone.utc)
            .isoformat(timespec="seconds")
            .replace("+00:00", "Z"),
            "pendingSha256": hashlib.sha256(pending_raw).hexdigest(),
            "schemaVersion": 1,
            "status": "RECOVERY_INGRESS_PROBE_AUTHORIZED",
            "transactionDirectory": str(self.transaction),
        }
        value.update(overrides)
        write_json(self.authorization_path, value)
        return value

    @contextlib.contextmanager
    def gate_paths(self):
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(recovery_gate, "ROOT", self.root))
            stack.enter_context(
                mock.patch.object(recovery_gate, "PENDING", self.pending_path)
            )
            stack.enter_context(
                mock.patch.object(
                    recovery_gate, "AUTHORIZATION", self.authorization_path
                )
            )
            stack.enter_context(
                mock.patch.object(recovery_gate, "OPERATION_LOCK", self.lock_path)
            )
            stack.enter_context(
                mock.patch.object(recovery_gate, "BOOT_ID", self.boot_id_path)
            )
            stack.enter_context(
                mock.patch.object(recovery_gate, "EVIDENCE", self.evidence)
            )
            stack.enter_context(
                mock.patch.object(
                    recovery_gate, "strict", side_effect=unchecked_strict
                )
            )
            yield

    @contextlib.contextmanager
    def root_lock_metadata(self):
        real_fstat = os.fstat
        gid = os.getgid()

        def root_fstat(descriptor: int):
            return self.RootLockStat(real_fstat(descriptor), gid)

        with mock.patch.object(
            recovery_gate.grp,
            "getgrnam",
            return_value=SimpleNamespace(gr_gid=gid),
        ), mock.patch.object(recovery_gate.os, "fstat", side_effect=root_fstat):
            yield

    @contextlib.contextmanager
    def updater_paths(self, *, atomic=None):
        if atomic is None:
            atomic = lambda path, value, **_kwargs: write_json(path, value)
        with contextlib.ExitStack() as stack:
            stack.enter_context(
                mock.patch.object(
                    release_updater, "RECOVERY_INGRESS_PENDING", self.pending_path
                )
            )
            stack.enter_context(
                mock.patch.object(
                    release_updater,
                    "RECOVERY_INGRESS_AUTHORIZATION",
                    self.authorization_path,
                )
            )
            stack.enter_context(
                mock.patch.object(release_updater, "require_root_controlled_file")
            )
            stack.enter_context(
                mock.patch.object(
                    release_updater,
                    "read_root_evidence_bytes",
                    side_effect=lambda path, **_kwargs: Path(path).read_bytes(),
                )
            )
            stack.enter_context(
                mock.patch.object(
                    release_updater, "current_boot_id", return_value=self.BOOT_ID
                )
            )
            stack.enter_context(
                mock.patch.object(
                    release_updater,
                    "utc_now",
                    return_value=datetime.now(timezone.utc)
                    .isoformat(timespec="seconds")
                    .replace("+00:00", "Z"),
                )
            )
            stack.enter_context(
                mock.patch.object(release_updater, "atomic_json", side_effect=atomic)
            )
            yield

    def test_no_lock_rejects_an_otherwise_exact_authorization(self):
        pending_raw = self.write_pending()
        self.write_authorization(pending_raw)
        with self.gate_paths(), self.root_lock_metadata(), mock.patch.object(
            recovery_gate, "validate_issuer_identity", return_value=4242
        ), self.assertRaisesRegex(recovery_gate.GateError, "not held"):
            recovery_gate.verify()
        self.assertTrue(self.pending_path.is_file())
        self.assertTrue(self.authorization_path.is_file())

    @unittest.skipUnless(os.name == "posix", "live flock ownership is POSIX-only")
    def test_live_issuer_holding_the_exact_lock_authorizes_only_its_probe_window(self):
        self.write_pending()
        descriptor = os.open(self.lock_path, os.O_RDONLY)
        try:
            recovery_gate.fcntl.flock(descriptor, recovery_gate.fcntl.LOCK_EX)
            with self.updater_paths():
                release_updater.authorize_recovery_ingress_probes(
                    transaction=self.transaction
                )
            with self.gate_paths(), self.root_lock_metadata():
                recovery_gate.verify()
        finally:
            recovery_gate.fcntl.flock(descriptor, recovery_gate.fcntl.LOCK_UN)
            os.close(descriptor)

        with self.gate_paths(), self.root_lock_metadata(), self.assertRaisesRegex(
            recovery_gate.GateError, "not held by its issuer"
        ):
            recovery_gate.verify()

    def test_wrong_boot_expired_and_wrong_pending_are_rejected_before_lock_use(self):
        cases = {
            "wrong-boot": {
                "bootId": "990d0b3d-37a1-4448-bb51-c27d34820163"
            },
            "expired": {
                "issuedAtUtc": (
                    datetime.now(timezone.utc) - timedelta(seconds=301)
                )
                .isoformat(timespec="seconds")
                .replace("+00:00", "Z")
            },
            "wrong-pending": {"pendingSha256": "f" * 64},
        }
        for label, overrides in cases.items():
            with self.subTest(case=label):
                pending_raw = self.write_pending()
                self.write_authorization(pending_raw, **overrides)
                with self.gate_paths(), mock.patch.object(
                    recovery_gate,
                    "validate_issuer_identity",
                    return_value=4242,
                ), mock.patch.object(
                    recovery_gate,
                    "operation_lock_is_held_by",
                    side_effect=AssertionError(
                        "invalid authorization must fail before lock acceptance"
                    ),
                ), self.assertRaises(recovery_gate.GateError):
                    recovery_gate.verify()

    def test_authorization_without_probes_publishes_no_terminal_and_stays_closed(self):
        self.write_pending()
        with self.updater_paths():
            release_updater.authorize_recovery_ingress_probes(
                transaction=self.transaction
            )
        self.assertTrue(self.pending_path.is_file())
        self.assertTrue(self.authorization_path.is_file())
        self.assertFalse((self.transaction / "recovery-receipt.json").exists())

        with self.gate_paths(), mock.patch.object(
            recovery_gate,
            "validate_issuer_identity",
            return_value=4242,
        ), mock.patch.object(
            recovery_gate,
            "operation_lock_is_held_by",
            side_effect=recovery_gate.GateError("recovery operation lock is not held"),
        ), self.assertRaisesRegex(recovery_gate.GateError, "not held"):
            recovery_gate.verify()
        self.assertTrue(self.pending_path.is_file())
        self.assertTrue(self.authorization_path.is_file())

    @unittest.skipUnless(os.name == "posix", "flock issuer binding is POSIX-only")
    def test_unrelated_lock_holder_cannot_reanimate_a_stale_authorization(self):
        self.write_pending()
        issuer_descriptor = os.open(self.lock_path, os.O_RDONLY)
        try:
            recovery_gate.fcntl.flock(issuer_descriptor, recovery_gate.fcntl.LOCK_EX)
            with self.updater_paths():
                release_updater.authorize_recovery_ingress_probes(
                    transaction=self.transaction
                )
        finally:
            recovery_gate.fcntl.flock(issuer_descriptor, recovery_gate.fcntl.LOCK_UN)
            os.close(issuer_descriptor)

        holder = subprocess.Popen(
            [
                sys.executable,
                "-c",
                (
                    "import fcntl,sys; h=open(sys.argv[1],'rb'); "
                    "fcntl.flock(h,fcntl.LOCK_EX); print('ready',flush=True); "
                    "sys.stdin.buffer.read(1)"
                ),
                str(self.lock_path),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            self.assertEqual(b"ready\n", holder.stdout.readline())
            with self.gate_paths(), self.root_lock_metadata(), self.assertRaises(
                recovery_gate.GateError
            ):
                recovery_gate.verify()
        finally:
            if holder.stdin is not None:
                holder.stdin.write(b"x")
                holder.stdin.close()
            holder.wait(timeout=5)
            if holder.stdout is not None:
                holder.stdout.close()
            if holder.stderr is not None:
                holder.stderr.close()

    def test_exact_receipt_reentry_before_authorization_unlink_is_immutable(self):
        self.write_pending()
        with self.updater_paths():
            release_updater.authorize_recovery_ingress_probes(
                transaction=self.transaction
            )
        receipt = {"schemaVersion": 1, "status": "completed"}
        receipt_path = self.transaction / "recovery-receipt.json"

        def fail_before_authorization_unlink(_path: Path):
            raise OSError("injected crash before authorization unlink")

        with self.updater_paths(), mock.patch.object(
            release_updater,
            "durable_unlink",
            side_effect=fail_before_authorization_unlink,
        ), self.assertRaisesRegex(OSError, "before authorization"):
            release_updater.complete_recovery_ingress(
                transaction=self.transaction, receipt=receipt
            )
        original = receipt_path.read_bytes()

        terminal_writer = mock.Mock(
            side_effect=lambda path, value, **_kwargs: write_json(path, value)
        )
        with self.updater_paths(atomic=terminal_writer), mock.patch.object(
            release_updater,
            "durable_unlink",
            side_effect=lambda path: Path(path).unlink(),
        ):
            release_updater.complete_recovery_ingress(
                transaction=self.transaction, receipt=receipt
            )
        terminal_writer.assert_not_called()
        self.assertEqual(original, receipt_path.read_bytes())
        self.assertFalse(self.authorization_path.exists())
        self.assertFalse(self.pending_path.exists())

    def test_exact_receipt_reentry_after_authorization_unlink_clears_pending(self):
        self.write_pending()
        with self.updater_paths():
            release_updater.authorize_recovery_ingress_probes(
                transaction=self.transaction
            )
        receipt = {"schemaVersion": 1, "status": "completed"}
        receipt_path = self.transaction / "recovery-receipt.json"

        def crash_before_pending_unlink(path: Path):
            if path == self.authorization_path:
                path.unlink()
                return
            raise OSError("injected crash before pending unlink")

        with self.updater_paths(), mock.patch.object(
            release_updater,
            "durable_unlink",
            side_effect=crash_before_pending_unlink,
        ), self.assertRaisesRegex(OSError, "before pending"):
            release_updater.complete_recovery_ingress(
                transaction=self.transaction, receipt=receipt
            )
        original = receipt_path.read_bytes()
        self.assertFalse(self.authorization_path.exists())
        self.assertTrue(self.pending_path.is_file())

        terminal_writer = mock.Mock(
            side_effect=lambda path, value, **_kwargs: write_json(path, value)
        )
        with self.updater_paths(atomic=terminal_writer), mock.patch.object(
            release_updater,
            "durable_unlink",
            side_effect=lambda path: Path(path).unlink(),
        ):
            release_updater.complete_recovery_ingress(
                transaction=self.transaction, receipt=receipt
            )
        terminal_writer.assert_not_called()
        self.assertEqual(original, receipt_path.read_bytes())
        self.assertFalse(self.pending_path.exists())

    def test_mismatched_existing_terminal_never_clears_either_gate(self):
        self.write_pending()
        with self.updater_paths():
            release_updater.authorize_recovery_ingress_probes(
                transaction=self.transaction
            )
        receipt = {"schemaVersion": 1, "status": "completed"}
        receipt_path = self.transaction / "recovery-receipt.json"
        write_json(receipt_path, {**receipt, "unexpected": True})

        with self.updater_paths(), mock.patch.object(
            release_updater, "durable_unlink"
        ) as unlink, self.assertRaisesRegex(
            release_updater.UpdaterError, "differs"
        ):
            release_updater.complete_recovery_ingress(
                transaction=self.transaction, receipt=receipt
            )
        unlink.assert_not_called()
        self.assertTrue(self.pending_path.is_file())
        self.assertTrue(self.authorization_path.is_file())

    def test_both_recovery_flows_delegate_terminal_probes_to_systemd(self):
        source = (
            PROJECT_ROOT / "deploy/updater/release_updater.py"
        ).read_text(encoding="utf-8")
        boundaries = (
            ("def finish_activation_recovery(", "\ndef validated_internal_active_origin("),
            ("def restore_previous_recovery(", "\ndef remain_contained_recovery("),
        )
        for start, end in boundaries:
            with self.subTest(flow=start):
                flow = source[source.index(start) : source.index(end)]
                commit = flow.index(
                    'commit_path = transaction / "recovery-commit.json"'
                )
                pending = flow.index("arm_recovery_ingress_pending(", commit)
                finalizer = flow.index(
                    "commit_recovery_ingress_for_systemd_finalizer(", pending
                )
                nginx = flow.index('start_unit("nginx.service")', finalizer)
                receipt = flow.index(
                    "read_systemd_finalized_recovery_receipt(", nginx
                )
                self.assertLess(commit, pending)
                self.assertLess(pending, finalizer)
                self.assertLess(finalizer, nginx)
                self.assertLess(nginx, receipt)
                self.assertNotIn("authorize_recovery_ingress_probes(", flow)
                self.assertNotIn("complete_recovery_ingress(", flow)
                self.assertNotIn("validate_static_entry(", flow)
                self.assertNotIn("run_oneshot_probe(", flow)

        verifier = (
            PROJECT_ROOT / "deploy/updater/recovery_commit_boot_verifier.py"
        ).read_text(encoding="utf-8")
        finalizer = verifier[
            verifier.index("def finalize_ingress(") : verifier.index(
                "\ndef datetime_now_utc("
            )
        ]
        validate = finalizer.index("validate_finalizing(")
        probes = finalizer.index("probe_committed_runtime(", validate)
        receipt = finalizer.index("atomic_json(receipt_path, completed)", probes)
        clear = finalizer.index("FINALIZING.unlink()", receipt)
        self.assertLess(validate, probes)
        self.assertLess(probes, receipt)
        self.assertLess(receipt, clear)

        nginx_override = (
            PROJECT_ROOT
            / "deploy/systemd/nginx-uten-imp-override.conf.example"
        ).read_text(encoding="utf-8")
        fatal_finalizer = (
            "ExecStartPost=/usr/bin/python3 -I "
            "/usr/local/libexec/uten-imp-release/"
            "recovery_commit_boot_verifier.py --finalize-ingress"
        )
        self.assertEqual(1, nginx_override.splitlines().count(fatal_finalizer))
        self.assertNotIn("ExecStartPost=-", nginx_override)
        service_lines = nginx_override.splitlines()
        self.assertEqual(1, service_lines.count("Restart=no"))
        self.assertFalse(
            any(line.startswith("RestartPreventExitStatus=") for line in service_lines)
        )
        self.assertNotIn("Restart=on-failure", service_lines)
        self.assertNotIn("Restart=always", service_lines)

        # Model the systemd policy decision after a fatal ExecStartPost signal:
        # Restart=no has no automatic second start transaction, independent of
        # whether the post-start verifier returned 78 or died by signal.
        starts = 1
        restart_policy = next(
            line.split("=", 1)[1]
            for line in service_lines
            if line.startswith("Restart=")
        )
        if restart_policy != "no":
            starts += 1
        self.assertEqual(1, starts)

    def test_nginx_start_failure_after_finalizer_authority_invokes_containment(self):
        marker_raw = canonical_bytes({"status": "failed-closed"})
        marker_sha = hashlib.sha256(marker_raw).hexdigest()
        target_manifest = {
            "commitSha": "a" * 40,
            "flywayHeadVersion": "253",
            "flywayMigrationSetSha256": "b" * 64,
            "manifestSha256": "c" * 64,
            "releaseSequence": 20260812001,
            "verified": True,
            "version": VERSION,
        }
        desired_boot = {unit: True for unit in release_updater.BOOT_UNITS}
        assessment = {
            "planSha256": "5" * 64,
            "state": {
                "activationFailure": {"sha256": marker_sha},
                "bootEnablementInProgress": None,
                "manifests": {VERSION: target_manifest},
                "recoveryContext": {
                    "finishTargetVersion": VERSION,
                    "originalBootEnablement": desired_boot,
                    "previousFlywayMigrationSetSha256": "b" * 64,
                    "previousVersion": "v2026.08.11-1",
                },
            },
        }
        database_receipt = {
            "detailPath": "/fixed/detail.json",
            "detailSha256": "d" * 64,
            "path": "/fixed/receipt.json",
            "sha256": "e" * 64,
        }
        live_database = {
            "databaseName": "uten_imp",
            "schemaName": "public",
        }
        transaction = self.transaction
        authority_published = False

        def publish_authority(**_kwargs):
            nonlocal authority_published
            authority_published = True

        def start(unit: str):
            if unit == "nginx.service":
                self.assertTrue(authority_published)
                raise release_updater.UpdaterError(
                    "injected Nginx ExecStartPost failure"
                )

        contain = mock.Mock()
        with contextlib.ExitStack() as stack:
            stack.enter_context(
                mock.patch.object(
                    release_updater,
                    "read_root_evidence_bytes",
                    return_value=marker_raw,
                )
            )
            stack.enter_context(
                mock.patch.object(release_updater, "assert_privilege_separation")
            )
            stack.enter_context(
                mock.patch.object(
                    release_updater,
                    "observe_installed_release",
                    return_value=target_manifest,
                )
            )
            stack.enter_context(
                mock.patch.object(
                    release_updater,
                    "load_installed_manifest",
                    return_value=target_manifest,
                )
            )
            for name in (
                "validate_detail_against_signed_manifest",
                "assert_privilege_separation",
                "require_root_controlled_file",
                "archive_root_evidence",
                "archive_interrupted_start_authorization",
                "start_application_authorized",
                "validate_health",
                "atomic_json",
                "write_runtime_authority",
                "restore_boot_enablement",
                "arm_recovery_ingress_pending",
            ):
                stack.enter_context(mock.patch.object(release_updater, name))
            stack.enter_context(mock.patch.object(release_updater, "run"))
            stack.enter_context(
                mock.patch.object(
                    release_updater,
                    "create_recovery_transaction",
                    return_value=transaction,
                )
            )
            stack.enter_context(
                mock.patch.object(
                    release_updater,
                    "verify_live_recovery_database",
                    return_value=live_database,
                )
            )
            stack.enter_context(
                mock.patch.object(
                    release_updater, "deployment_profile", return_value="production"
                )
            )
            stack.enter_context(
                mock.patch.object(
                    release_updater,
                    "installed_manifest_sha256",
                    return_value="c" * 64,
                )
            )
            stack.enter_context(
                mock.patch.object(release_updater, "unit_active", return_value=True)
            )
            stack.enter_context(
                mock.patch.object(release_updater, "start_unit", side_effect=start)
            )
            finalizer = stack.enter_context(
                mock.patch.object(
                    release_updater,
                    "commit_recovery_ingress_for_systemd_finalizer",
                    side_effect=publish_authority,
                )
            )
            stack.enter_context(
                mock.patch.object(
                    release_updater, "contain_recovery_failure", contain
                )
            )
            with self.assertRaisesRegex(
                release_updater.UpdaterError, "ExecStartPost failure"
            ):
                release_updater.finish_activation_recovery(
                    assessment=assessment,
                    approval_reference="CHG-2026-0812-NGINX-FAIL",
                    database_receipt=database_receipt,
                )

        finalizer.assert_called_once()
        contain.assert_called_once()
        self.assertEqual(transaction, contain.call_args.kwargs["transaction"])
        self.assertIn(
            "ExecStartPost failure",
            str(contain.call_args.kwargs["recovery_error"]),
        )


class RuntimeStartAuthorizationIssuerBindingTest(unittest.TestCase):
    class RootLockStat:
        def __init__(self, details, gid: int):
            self._details = details
            self.st_mode = stat.S_IFREG | 0o660
            self.st_uid = 0
            self.st_gid = gid
            self.st_nlink = 1

        def __getattr__(self, name):
            return getattr(self._details, name)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.lock_path = Path(self.temporary.name) / "operation.lock"
        self.lock_path.write_bytes(b"")
        self.lock_path.chmod(0o660)

    def tearDown(self):
        self.temporary.cleanup()

    @contextlib.contextmanager
    def runtime_lock_fixture(self):
        real_fstat = os.fstat
        gid = os.getgid()

        def root_fstat(descriptor: int):
            return self.RootLockStat(real_fstat(descriptor), gid)

        with mock.patch.object(
            runtime_boot, "OPERATION_LOCK", self.lock_path
        ), mock.patch.object(
            runtime_boot.grp,
            "getgrnam",
            return_value=SimpleNamespace(gr_gid=gid),
        ), mock.patch.object(
            runtime_boot.os, "fstat", side_effect=root_fstat
        ):
            yield

    @unittest.skipUnless(os.name == "posix", "live /proc flock binding is POSIX-only")
    def test_release_producer_identity_and_same_process_lock_are_accepted(self):
        descriptor = os.open(self.lock_path, os.O_RDONLY)
        try:
            runtime_boot.fcntl.flock(descriptor, runtime_boot.fcntl.LOCK_EX)
            authorization = release_updater.recovery_issuer_identity(os.getpid())
            with self.runtime_lock_fixture():
                issuer = runtime_boot._validate_authorization_issuer(authorization)
                self.assertEqual(os.getpid(), issuer)
                self.assertTrue(runtime_boot._operation_lock_is_held_by(issuer))
        finally:
            runtime_boot.fcntl.flock(descriptor, runtime_boot.fcntl.LOCK_UN)
            os.close(descriptor)

    @unittest.skipUnless(os.name == "posix", "live /proc flock binding is POSIX-only")
    def test_lock_transfer_to_another_process_cannot_reanimate_live_issuer(self):
        authorization = release_updater.recovery_issuer_identity(os.getpid())
        issuer = runtime_boot._validate_authorization_issuer(authorization)
        holder = subprocess.Popen(
            [
                sys.executable,
                "-c",
                (
                    "import fcntl,sys; h=open(sys.argv[1],'rb'); "
                    "fcntl.flock(h,fcntl.LOCK_EX); print('ready',flush=True); "
                    "sys.stdin.buffer.read(1)"
                ),
                str(self.lock_path),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            self.assertEqual(b"ready\n", holder.stdout.readline())
            with self.runtime_lock_fixture():
                self.assertFalse(runtime_boot._operation_lock_is_held_by(issuer))
        finally:
            if holder.stdin is not None:
                holder.stdin.write(b"x")
                holder.stdin.close()
            holder.wait(timeout=5)
            if holder.stdout is not None:
                holder.stdout.close()
            if holder.stderr is not None:
                holder.stderr.close()

    @unittest.skipUnless(os.name == "posix", "live /proc issuer identity is POSIX-only")
    def test_start_ticks_executable_and_command_line_drift_are_rejected(self):
        exact = release_updater.recovery_issuer_identity(os.getpid())
        cases = {
            "start-ticks": {
                "issuerStartTimeTicks": exact["issuerStartTimeTicks"] + 1
            },
            "executable-path": {
                "issuerExecutablePath": "/usr/bin/python3-different"
            },
            "executable-bytes": {"issuerExecutableSha256": "f" * 64},
            "command-line": {"issuerCommandLineSha256": "e" * 64},
        }
        for label, changed in cases.items():
            with self.subTest(case=label), self.assertRaises(
                runtime_boot.BootVerificationError
            ):
                runtime_boot._validate_authorization_issuer({**exact, **changed})

    @unittest.skipUnless(os.name == "posix", "live /proc issuer identity is POSIX-only")
    def test_start_authorization_producer_publishes_the_exact_consumer_identity_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            authorization_dir = root / "start-authorization"
            authorization_path = authorization_dir / "start-authorization.json"
            marker = root / "recovery-in-progress.json"
            marker.write_bytes(b'{"status":"recovering"}\n')
            target = root / VERSION
            target.mkdir()
            identity = release_updater.recovery_issuer_identity(os.getpid())
            database_identity = {
                "canonicalHistorySha256": "1" * 64,
                "headVersion": 1,
                "roleAclContractSha256": "2" * 64,
                "signedProjectionSha256": "3" * 64,
                "successfulMigrationCount": 1,
                "systemIdentifier": "1234567890123456789",
                "timeline": 1,
            }
            manifest = {
                "commitSha": "4" * 40,
                "releaseSequence": release_updater.release_guard.version_sequence(
                    VERSION
                ),
                "version": VERSION,
            }
            contract = {"contractId": "internal-test-local-v1"}
            contract_sha = "5" * 64

            def atomic(path: Path, value: object, **_kwargs):
                write_json(path, value)

            with mock.patch.object(
                release_updater, "RECOVERY_IN_PROGRESS_MARKER", marker
            ), mock.patch.object(
                release_updater, "START_AUTHORIZATION_DIR", authorization_dir
            ), mock.patch.object(
                release_updater, "START_AUTHORIZATION", authorization_path
            ), mock.patch.object(
                release_updater, "require_runtime_boot_verifier"
            ), mock.patch.object(
                release_updater, "require_root_controlled_file"
            ), mock.patch.object(
                release_updater, "fsync_directory"
            ), mock.patch.object(
                release_updater.os, "chown"
            ), mock.patch.object(
                release_updater.os, "urandom", return_value=b"\x06" * 16
            ), mock.patch.object(
                release_updater,
                "current_boot_id",
                return_value="880d0b3d-37a1-4448-bb51-c27d34820163",
            ), mock.patch.object(
                release_updater,
                "utc_now",
                return_value="2026-08-13T08:00:00Z",
            ), mock.patch.object(
                release_updater,
                "runtime_database_identity",
                return_value=database_identity,
            ), mock.patch.object(
                release_updater,
                "recovery_issuer_identity",
                return_value=identity,
            ) as producer, mock.patch.object(
                release_updater,
                "installed_manifest_sha256",
                return_value="7" * 64,
            ), mock.patch.object(
                release_updater, "deployment_profile", return_value="internal-test"
            ), mock.patch.object(
                release_updater,
                "internal_test_runtime_contract",
                return_value=(contract, contract_sha),
            ), mock.patch.object(
                release_updater, "atomic_json", side_effect=atomic
            ):
                authorization_id = release_updater.prepare_start_authorization(
                    mode="recovery",
                    marker=marker,
                    target=target,
                    manifest=manifest,
                    live_evidence={"fixture": True},
                )
                value = json.loads(authorization_path.read_text(encoding="utf-8"))
                self.assertEqual(
                    "start-authorization-v1",
                    release_updater.validate_start_authorization(value),
                )

            self.assertEqual("06" * 16, authorization_id)
            producer.assert_called_once_with(os.getpid())
            for key, expected in identity.items():
                self.assertEqual(expected, value[key], key)
            self.assertEqual(contract["contractId"], value["runtimeContractId"])
            self.assertEqual(contract_sha, value["runtimeContractSha256"])

    def test_internal_unit_exposes_full_proc_only_to_the_root_prestart_gate(self):
        unit = (
            PROJECT_ROOT
            / "deploy/systemd/uten-imp-internal-test.service.example"
        ).read_text(encoding="utf-8")
        self.assertIn("ProtectProc=invisible", unit)
        self.assertIn("ProcSubset=all", unit)
        self.assertIn(
            "ExecStartPre=+/usr/bin/python3 -I "
            "/usr/local/libexec/uten-imp-release/runtime_boot_verifier.py",
            unit,
        )


class RecoveryIngressBootGateTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "release"
        self.evidence = self.root / "recovery-evidence"
        self.transaction = self.evidence / ("5" * 16 + "-recovery-fixture")
        self.transaction.mkdir(parents=True)
        self.pending_path = self.root / "recovery-ingress-pending.json"
        self.authorization_path = (
            self.root / "recovery-ingress-authorization.json"
        )
        self.finalizing_path = self.root / "recovery-ingress-finalizing.json"
        self.failure_path = self.root / "activation-failed.json"
        self.database_receipt_path = (
            self.root / "database-receipts" / "recovery-fixture.json"
        )
        self.database_detail_path = Path(
            "/var/lib/uten-imp-backup/acceptance-receipts/"
            "recovery-fixture-detail.json"
        )
        self.database_detail_fixture = (
            Path(self.temporary.name)
            / "acceptance-receipts"
            / self.database_detail_path.name
        )

    def tearDown(self):
        self.temporary.cleanup()

    def commit(self) -> dict[str, object]:
        marker_sha = hashlib.sha256(
            canonical_bytes({"status": "failed-closed"})
        ).hexdigest()
        approval = "CHG-2026-0812-RECOVERY"
        completed = "2026-08-12T11:58:00Z"
        migration_sha = "8" * 64
        detail = {
            "approvalReference": approval,
            "completedAtUtc": completed,
            "flywayHeadVersion": "253",
            "flywayMigrationSetSha256": migration_sha,
            "receiptType": "backup-acceptance-detail",
            "schemaVersion": 1,
            "successful": True,
            "targetVersion": VERSION,
        }
        detail_raw = write_json(self.database_detail_fixture, detail)
        detail_sha = hashlib.sha256(detail_raw).hexdigest()
        receipt = {
            "approvalReference": approval,
            "completedAtUtc": completed,
            "evidenceReference": (
                f"path={self.database_detail_path};sha256={detail_sha}"
            ),
            "flywayHeadVersion": "253",
            "flywayMigrationSetSha256": migration_sha,
            "receiptType": "backup",
            "schemaVersion": 1,
            "successful": True,
            "targetVersion": VERSION,
        }
        receipt_raw = write_json(self.database_receipt_path, receipt)
        return {
            "action": "finish-activation",
            "approvalReference": approval,
            "committedAtUtc": "2026-08-12T12:00:00Z",
            "databaseReceiptPath": str(self.database_receipt_path),
            "databaseReceiptSha256": hashlib.sha256(receipt_raw).hexdigest(),
            "databaseDetailPath": str(self.database_detail_path),
            "databaseDetailSha256": detail_sha,
            "desiredBootEnablement": {
                "nginx.service": True,
                "uten-imp-entry-watchdog.timer": True,
                "uten-imp-watchdog.timer": True,
                "uten-imp.service": True,
            },
            "liveDatabaseEvidence": {
                "databaseName": "uten_imp",
                "dataDirectory": "/data/postgresql/16/main",
                "flyway": {
                    "canonicalHistorySha256": "9" * 64,
                    "headVersion": 253,
                    "signedProjectionSha256": "a" * 64,
                    "successfulMigrationCount": 253,
                },
                "roleAclContractSha256": "b" * 64,
                "schemaName": "public",
                "serverPort": 5432,
                "serverVersionNum": 160010,
                "systemdMainPid": 4242,
                "systemIdentifier": "1234567890123456789",
                "timeline": 1,
                "verifiedAtUtc": "2026-08-12T11:58:30Z",
                "verifierSha256": "c" * 64,
            },
            "markerSha256": marker_sha,
            "manifestSha256": "4" * 64,
            "planSha256": "5" * 64,
            "schemaVersion": 1,
            "status": "runtime-committed-pending-ingress",
            "targetVersion": VERSION,
            "transactionDirectory": str(self.transaction),
        }

    def prepare_pending(self, commit: dict[str, object]) -> dict[str, object]:
        commit_raw = write_json(self.transaction / "recovery-commit.json", commit)
        pending = {
            "action": commit["action"],
            "commitSha256": hashlib.sha256(commit_raw).hexdigest(),
            "markerSha256": commit["markerSha256"],
            "planSha256": commit["planSha256"],
            "schemaVersion": 1,
            "status": "RECOVERY_COMMITTED_PENDING_INGRESS",
            "targetVersion": commit["targetVersion"],
            "transactionDirectory": str(self.transaction),
        }
        write_json(self.pending_path, pending)
        return pending

    def prepare_completed_archives(self, commit: dict[str, object]) -> None:
        write_json(
            self.transaction / "activation-failed.original.json",
            {"status": "failed-closed"},
        )
        write_json(
            self.transaction / "recovery-in-progress.completed.json",
            {
                "action": commit["action"],
                "approvalReference": commit["approvalReference"],
                "databaseReceiptPath": commit["databaseReceiptPath"],
                "databaseReceiptSha256": commit["databaseReceiptSha256"],
                "desiredBootEnablement": commit["desiredBootEnablement"],
                "markerSha256": commit["markerSha256"],
                "planSha256": commit["planSha256"],
                "schemaVersion": 1,
                "startedAtUtc": "2026-08-12T11:59:00Z",
                "targetVersion": commit["targetVersion"],
                "transactionDirectory": commit["transactionDirectory"],
            },
        )
        write_json(
            self.transaction / "boot-enablement.recovery.json",
            {
                "commitSha": "a" * 40,
                "desiredBootEnablement": commit["desiredBootEnablement"],
                "releaseSequence": 20260812001,
                "schemaVersion": 1,
                "startedAtUtc": "2026-08-12T11:59:30Z",
                "version": commit["targetVersion"],
            },
        )

    def prepare_finalizing(self, commit: dict[str, object]) -> dict[str, object]:
        pending = self.prepare_pending(commit)
        pending_raw = self.pending_path.read_bytes()
        archived = self.transaction / "recovery-ingress-pending.committed.json"
        os.replace(self.pending_path, archived)
        finalizing = {
            "action": pending["action"],
            "commitSha256": pending["commitSha256"],
            "markerSha256": pending["markerSha256"],
            "pendingSha256": hashlib.sha256(pending_raw).hexdigest(),
            "planSha256": pending["planSha256"],
            "schemaVersion": 1,
            "status": "RECOVERY_INGRESS_DURABLY_AUTHORIZED_PENDING_PROBES",
            "targetVersion": pending["targetVersion"],
            "transactionDirectory": str(self.transaction),
        }
        write_json(self.finalizing_path, finalizing)
        return finalizing

    def receipt(self, commit: dict[str, object]) -> dict[str, object]:
        receipt = dict(commit)
        receipt.pop("committedAtUtc")
        receipt["completedAtUtc"] = "2026-08-12T12:01:00Z"
        receipt["status"] = "completed"
        return receipt

    def authorization(
        self, pending_raw: bytes, *, pending_sha256: str | None = None
    ) -> dict[str, object]:
        return {
            "bootId": "880d0b3d-37a1-4448-bb51-c27d34820163",
            "issuerCommandLineSha256": "a" * 64,
            "issuerExecutablePath": "/usr/bin/python3.14",
            "issuerExecutableSha256": "b" * 64,
            "issuerPid": 4242,
            "issuerStartTimeTicks": 123456,
            "issuedAtUtc": "2026-08-12T12:00:30Z",
            "pendingSha256": pending_sha256
            or hashlib.sha256(pending_raw).hexdigest(),
            "schemaVersion": 1,
            "status": "RECOVERY_INGRESS_PROBE_AUTHORIZED",
            "transactionDirectory": str(self.transaction),
        }

    def patches(self):
        return contextlib.ExitStack()

    def invoke_main(self) -> tuple[int, str]:
        stderr = io.StringIO()

        def strict_fixture(path: Path, label: str):
            actual = (
                self.database_detail_fixture
                if Path(path) == self.database_detail_path
                else Path(path)
            )
            return unchecked_strict(actual, label)

        with mock.patch.object(recovery_boot, "ROOT", self.root), mock.patch.object(
            recovery_boot, "PENDING", self.pending_path
        ), mock.patch.object(
            recovery_boot, "AUTHORIZATION", self.authorization_path
        ), mock.patch.object(
            recovery_boot, "FINALIZING", self.finalizing_path
        ), mock.patch.object(
            recovery_boot, "FAILURE", self.failure_path
        ), mock.patch.object(
            recovery_boot, "EVIDENCE", self.evidence
        ), mock.patch.object(
            recovery_boot, "strict", side_effect=strict_fixture
        ), mock.patch.object(
            recovery_boot, "require_root_directory"
        ), mock.patch.object(
            recovery_boot,
            "OperationLock",
            side_effect=lambda: contextlib.nullcontext(),
        ), mock.patch.object(
            recovery_boot, "fsync_directory"
        ), mock.patch.object(
            recovery_boot.os, "geteuid", return_value=0
        ), mock.patch.object(
            recovery_boot.sys, "argv", [str(UPDATER_DIR / "recovery_commit_boot_verifier.py")]
        ), contextlib.redirect_stderr(stderr):
            return recovery_boot.main(), stderr.getvalue()

    def invoke_finalize(
        self, *, probe_side_effect: BaseException | None = None
    ) -> tuple[int, str, mock.Mock]:
        stderr = io.StringIO()

        def strict_fixture(path: Path, label: str):
            actual = (
                self.database_detail_fixture
                if Path(path) == self.database_detail_path
                else Path(path)
            )
            return unchecked_strict(actual, label)

        probe = mock.Mock(side_effect=probe_side_effect)
        with mock.patch.object(recovery_boot, "ROOT", self.root), mock.patch.object(
            recovery_boot, "PENDING", self.pending_path
        ), mock.patch.object(
            recovery_boot, "AUTHORIZATION", self.authorization_path
        ), mock.patch.object(
            recovery_boot, "FINALIZING", self.finalizing_path
        ), mock.patch.object(
            recovery_boot, "EVIDENCE", self.evidence
        ), mock.patch.object(
            recovery_boot, "strict", side_effect=strict_fixture
        ), mock.patch.object(
            recovery_boot, "require_root_directory"
        ), mock.patch.object(
            recovery_boot, "probe_committed_runtime", probe
        ), mock.patch.object(
            recovery_boot, "fsync_directory"
        ), mock.patch.object(
            recovery_boot.os, "geteuid", return_value=0
        ), contextlib.redirect_stderr(stderr):
            return recovery_boot.finalize_ingress(), stderr.getvalue(), probe

    def test_state_lock_refuses_systemd_finalizing_and_releases_lock(self):
        lock_path = Path(self.temporary.name) / "operation.lock"
        lock_path.write_bytes(b"")
        lock_path.chmod(0o660)
        write_json(self.finalizing_path, {"status": "pending-probes"})
        actual_fstat = os.fstat

        def root_lock_stat(descriptor: int):
            details = actual_fstat(descriptor)
            return SimpleNamespace(
                st_mode=stat.S_IFREG | 0o660,
                st_uid=0,
                st_gid=4242,
                st_nlink=1,
                st_dev=details.st_dev,
                st_ino=details.st_ino,
                st_size=details.st_size,
            )

        guard = release_updater.StateLock(lock_path)
        with mock.patch.object(
            release_updater,
            "RECOVERY_INGRESS_FINALIZING",
            self.finalizing_path,
        ), mock.patch.object(
            release_updater, "require_real_directory"
        ), mock.patch.object(
            release_updater, "require_root_controlled_file"
        ) as validate_finalizing, mock.patch.object(
            release_updater, "system_group_id", return_value=4242
        ), mock.patch.object(
            release_updater.os, "fstat", side_effect=root_lock_stat
        ), self.assertRaisesRegex(
            release_updater.UpdaterError,
            "still owned by the fixed systemd finalizer",
        ):
            guard.__enter__()

        validate_finalizing.assert_called_once_with(
            self.finalizing_path, secret=True
        )
        self.assertIsNone(guard.descriptor)
        descriptor = os.open(lock_path, os.O_RDWR)
        try:
            release_updater.fcntl.flock(
                descriptor,
                release_updater.fcntl.LOCK_EX
                | release_updater.fcntl.LOCK_NB,
            )
            release_updater.fcntl.flock(
                descriptor, release_updater.fcntl.LOCK_UN
            )
        finally:
            os.close(descriptor)

    def test_ordinary_state_lock_refuses_a_published_db_worker_lease(self):
        """Close the dispatcher publish-to-systemctl reverse race.

        Once the fixed worker request is durable, no unrelated stage,
        activation, or recovery transaction may acquire the global release
        gate and publish FINALIZING before PID 1 starts the matching worker.
        """

        lock_path = Path(self.temporary.name) / "operation-worker.lock"
        lock_path.write_bytes(b"")
        lock_path.chmod(0o660)
        worker_request = Path(self.temporary.name) / "worker-request.json"
        write_json(
            worker_request,
            {
                "approvalReference": "CHG-2026-0813-WORKER-LEASE",
                "kind": "uten-imp-internal-test-db-worker-request",
                "requestId": "1" * 32,
                "schemaVersion": 1,
                "status": "AUTHORIZED_FIXED_CGROUP",
                "version": VERSION,
            },
        )
        worker_request.chmod(0o600)
        actual_fstat = os.fstat

        def root_lock_stat(descriptor: int):
            details = actual_fstat(descriptor)
            return SimpleNamespace(
                st_mode=stat.S_IFREG | 0o660,
                st_uid=0,
                st_gid=4242,
                st_nlink=1,
                st_dev=details.st_dev,
                st_ino=details.st_ino,
                st_size=details.st_size,
            )

        guard = release_updater.StateLock(lock_path)
        with mock.patch.object(
            release_updater,
            "INTERNAL_TEST_DB_WORKER_REQUEST",
            worker_request,
            create=True,
        ), mock.patch.object(
            release_updater, "require_real_directory"
        ), mock.patch.object(
            release_updater, "require_root_controlled_file"
        ), mock.patch.object(
            release_updater,
            "read_root_evidence_bytes",
            side_effect=lambda path, **_kwargs: path.read_bytes(),
        ), mock.patch.object(
            release_updater, "system_group_id", return_value=4242
        ), mock.patch.object(
            release_updater.os, "fstat", side_effect=root_lock_stat
        ), self.assertRaisesRegex(
            release_updater.UpdaterError,
            "database commissioner|worker request|worker lease",
        ):
            guard.__enter__()

        self.assertIsNone(guard.descriptor)
        self.assertTrue(worker_request.is_file())
        self.assertFalse(self.finalizing_path.exists())

        request_sha = hashlib.sha256(worker_request.read_bytes()).hexdigest()
        worker_guard = release_updater.StateLock(
            lock_path,
            internal_test_worker_request_sha256=request_sha,
        )
        with mock.patch.object(
            release_updater,
            "INTERNAL_TEST_DB_WORKER_REQUEST",
            worker_request,
        ), mock.patch.object(
            release_updater, "require_real_directory"
        ), mock.patch.object(
            release_updater, "require_root_controlled_file"
        ), mock.patch.object(
            release_updater,
            "read_root_evidence_bytes",
            side_effect=lambda path, **_kwargs: path.read_bytes(),
        ), mock.patch.object(
            release_updater, "system_group_id", return_value=4242
        ), mock.patch.object(
            release_updater.os, "fstat", side_effect=root_lock_stat
        ):
            with worker_guard:
                self.assertIsNotNone(worker_guard.descriptor)
        self.assertIsNone(worker_guard.descriptor)

    def test_finalizing_gate_precedes_staging_candidate_directory_creation(self):
        """Even resumable staging must not write before the global gate."""

        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state"
            state.mkdir(mode=0o750)
            candidates = state / "candidates"

            class FinalizingStateLock:
                def __init__(self, _path: Path):
                    pass

                def __enter__(self):
                    raise release_updater.UpdaterError(
                        "recovery ingress finalization is still owned"
                    )

                def __exit__(self, *_args):
                    return False

            args = SimpleNamespace(
                allowed_signers="/fixed/allowed_signers",
                lock_file="/fixed/operation.lock",
                state_dir=str(state),
            )
            with mock.patch.object(
                release_updater.os, "geteuid", return_value=4242
            ), mock.patch.object(
                release_updater, "require_real_directory"
            ), mock.patch.object(
                release_updater, "report_capacity"
            ), mock.patch.object(
                release_updater, "authorized_key_ids", return_value={"fixture"}
            ), mock.patch.object(
                release_updater, "StateLock", FinalizingStateLock
            ), mock.patch.object(
                release_updater, "oss_download"
            ) as download, self.assertRaisesRegex(
                release_updater.UpdaterError, "finalization is still owned"
            ):
                release_updater.stage_release(args)

            self.assertFalse(candidates.exists())
            download.assert_not_called()

    def test_pid1_probe_contract_dynamically_checks_all_entry_boundaries(self):
        commit = self.commit()
        self.prepare_completed_archives(commit)
        requests: list[tuple[int, str]] = []
        systemd_calls: list[list[str]] = []

        class Response:
            def __init__(self, status: int, content_type: str, body: bytes):
                self.status = status
                self._content_type = content_type
                self._body = body

            def read(self, _maximum: int) -> bytes:
                return self._body

            def getheader(self, name: str, default: str = "") -> str:
                return self._content_type if name == "Content-Type" else default

        class Connection:
            def __init__(self, _host: str, port: int, *, timeout: int):
                self.port = port
                self.path = ""
                self.timeout = timeout

            def request(self, _method: str, path: str, *, headers: dict[str, str]):
                self.path = path
                requests.append((self.port, path))

            def getresponse(self):
                if self.port == 8080 and self.path.startswith("/actuator/health"):
                    return Response(200, "application/json", b'{"status":"UP"}')
                if self.port == 8080 and self.path == "/actuator/info":
                    return Response(404, "application/json", b"")
                if self.port == 8081 and self.path == "/index.html":
                    body = (
                        '<meta name="uten-release-version" content="'
                        + VERSION
                        + '">flutter_bootstrap.js'
                    ).encode("ascii")
                    return Response(200, "text/html; charset=utf-8", body)
                if self.port == 8081 and self.path == "/version.json":
                    return Response(
                        200,
                        "application/json",
                        canonical_bytes(
                            {
                                "commitSha": "a" * 40,
                                "product": "uten-imp",
                                "releaseSequence": 20260812001,
                                "schemaVersion": 1,
                                "version": VERSION,
                            }
                        ),
                    )
                raise AssertionError(f"unexpected HTTP probe: {self.port} {self.path}")

            def close(self):
                return None

        def systemctl(command: list[str], **_kwargs):
            systemd_calls.append(command)
            if command[1] == "start":
                return SimpleNamespace(returncode=0, stdout=b"")
            if command[1] == "show":
                return SimpleNamespace(
                    returncode=0,
                    stdout=b"Result=success\nExecMainStatus=0\n",
                )
            raise AssertionError(f"unexpected systemd probe: {command}")

        with mock.patch.object(
            recovery_boot.http.client, "HTTPConnection", Connection
        ), mock.patch.object(
            recovery_boot.subprocess, "run", side_effect=systemctl
        ), mock.patch.object(
            recovery_boot,
            "strict",
            side_effect=lambda path, label: unchecked_strict(Path(path), label),
        ):
            recovery_boot.probe_committed_runtime(commit, self.transaction)

        self.assertEqual(
            [
                (8080, "/actuator/health"),
                (8080, "/actuator/health/liveness"),
                (8080, "/actuator/health/readiness"),
                (8080, "/actuator/info"),
                (8081, "/index.html"),
                (8081, "/version.json"),
                # The finalizer runs as Nginx ExecStartPost.  Starting either
                # watchdog oneshot from inside that job would deadlock because
                # the entry watchdog is ordered After=nginx.service.  Exercise
                # the same bounded observations directly instead.
                (8080, "/actuator/health/liveness"),
                (8080, "/actuator/health/readiness"),
                (8081, "/index.html"),
            ],
            requests,
        )
        self.assertEqual([], systemd_calls)

    def test_pid1_finalizer_completes_without_the_updater_process(self):
        commit = self.commit()
        self.prepare_finalizing(commit)
        self.prepare_completed_archives(commit)

        result, stderr, probe = self.invoke_finalize()

        self.assertEqual(0, result, stderr)
        probe.assert_called_once_with(commit, self.transaction)
        self.assertFalse(self.finalizing_path.exists())
        self.assertFalse(self.pending_path.exists())
        receipt = json.loads(
            (self.transaction / "recovery-receipt.json").read_text(
                encoding="utf-8"
            )
        )
        expected = dict(commit)
        expected.pop("committedAtUtc")
        expected["completedAtUtc"] = receipt["completedAtUtc"]
        expected["status"] = "completed"
        self.assertEqual(expected, receipt)

    def test_pid1_probe_failure_keeps_finalizing_and_never_writes_terminal(self):
        commit = self.commit()
        self.prepare_finalizing(commit)
        self.prepare_completed_archives(commit)

        result, stderr, probe = self.invoke_finalize(
            probe_side_effect=recovery_boot.VerificationError(
                "injected systemd probe failure"
            )
        )

        self.assertEqual(78, result)
        self.assertIn("injected systemd probe failure", stderr)
        probe.assert_called_once_with(commit, self.transaction)
        self.assertTrue(self.finalizing_path.is_file())
        self.assertFalse((self.transaction / "recovery-receipt.json").exists())

    def test_killed_pid1_finalizer_leaves_boot_containable_authority(self):
        commit = self.commit()
        self.prepare_finalizing(commit)
        self.prepare_completed_archives(commit)
        result, stderr, probe = self.invoke_finalize(
            probe_side_effect=SystemExit(137)
        )
        self.assertEqual(78, result)
        self.assertIn("RECOVERY_INGRESS_FINALIZE_NO_GO", stderr)
        probe.assert_called_once_with(commit, self.transaction)
        self.assertTrue(self.finalizing_path.is_file())
        self.assertFalse((self.transaction / "recovery-receipt.json").exists())

        with mock.patch.object(
            recovery_boot, "converge_entry_unit_closed"
        ) as close:
            result, stderr = self.invoke_main()
        self.assertEqual(0, result, stderr)
        self.assertEqual(len(recovery_boot.ENTRY_UNITS), close.call_count)
        self.assertTrue(self.failure_path.is_file())
        self.assertFalse(self.finalizing_path.exists())

    def test_actual_finalizer_authority_is_durable_before_start_failure_reboot(self):
        commit = self.commit()
        pending = self.prepare_pending(commit)
        commit_path = self.transaction / "recovery-commit.json"
        pending_raw = self.pending_path.read_bytes()
        archived = self.transaction / "recovery-ingress-pending.committed.json"

        def strict_value(raw: bytes, _label: str):
            return json.loads(raw.decode("utf-8"))

        with mock.patch.object(
            release_updater, "RECOVERY_INGRESS_PENDING", self.pending_path
        ), mock.patch.object(
            release_updater,
            "RECOVERY_INGRESS_AUTHORIZATION",
            self.authorization_path,
        ), mock.patch.object(
            release_updater, "RECOVERY_INGRESS_FINALIZING", self.finalizing_path
        ), mock.patch.object(
            release_updater, "DEFAULT_ROOT_STATE_DIR", self.root
        ), mock.patch.object(
            release_updater, "require_root_controlled_file"
        ), mock.patch.object(
            release_updater,
            "read_root_evidence_bytes",
            side_effect=lambda path, **_kwargs: Path(path).read_bytes(),
        ), mock.patch.object(
            release_updater, "strict_json_object", side_effect=strict_value
        ), mock.patch.object(
            release_updater, "fsync_directory"
        ), mock.patch.object(
            release_updater,
            "atomic_json",
            side_effect=lambda path, value, **_kwargs: write_json(path, value),
        ):
            release_updater.commit_recovery_ingress_for_systemd_finalizer(
                transaction=self.transaction, commit_path=commit_path
            )

        self.assertFalse(self.pending_path.exists())
        self.assertTrue(archived.is_file())
        self.assertEqual(pending_raw, archived.read_bytes())
        finalizing = json.loads(self.finalizing_path.read_text(encoding="utf-8"))
        self.assertEqual(
            "RECOVERY_INGRESS_DURABLY_AUTHORIZED_PENDING_PROBES",
            finalizing["status"],
        )
        self.assertEqual(
            hashlib.sha256(pending_raw).hexdigest(),
            finalizing["pendingSha256"],
        )
        for key in (
            "action",
            "commitSha256",
            "markerSha256",
            "planSha256",
            "targetVersion",
            "transactionDirectory",
        ):
            self.assertEqual(pending[key], finalizing[key])

        # Model systemctl start failing before ExecStartPost reaches a terminal
        # receipt.  The next boot consumes the durable pointer and re-closes.
        self.prepare_completed_archives(commit)
        with mock.patch.object(
            recovery_boot, "converge_entry_unit_closed"
        ) as close:
            result, stderr = self.invoke_main()
        self.assertEqual(0, result, stderr)
        self.assertEqual(len(recovery_boot.ENTRY_UNITS), close.call_count)
        self.assertTrue(self.failure_path.is_file())
        self.assertFalse(self.finalizing_path.exists())

    def test_terminal_write_then_pointer_unlink_failure_is_idempotent(self):
        commit = self.commit()
        self.prepare_finalizing(commit)
        self.prepare_completed_archives(commit)
        real_unlink = type(self.finalizing_path).unlink

        def fail_finalizing_unlink(path: Path, *args, **kwargs):
            if Path(path) == self.finalizing_path:
                raise OSError("injected finalizing unlink failure")
            return real_unlink(path, *args, **kwargs)

        with mock.patch.object(
            type(self.finalizing_path),
            "unlink",
            autospec=True,
            side_effect=fail_finalizing_unlink,
        ):
            first, stderr, first_probe = self.invoke_finalize()
        self.assertEqual(78, first)
        self.assertIn("finalizing unlink failure", stderr)
        first_probe.assert_called_once()
        receipt_path = self.transaction / "recovery-receipt.json"
        original = receipt_path.read_bytes()
        self.assertTrue(self.finalizing_path.is_file())

        second, stderr, second_probe = self.invoke_finalize()
        self.assertEqual(0, second, stderr)
        second_probe.assert_called_once()
        self.assertEqual(original, receipt_path.read_bytes())
        self.assertFalse(self.finalizing_path.exists())

    def test_reboot_with_unfinished_finalizer_recontains_entry(self):
        commit = self.commit()
        self.prepare_finalizing(commit)
        self.prepare_completed_archives(commit)
        with mock.patch.object(
            recovery_boot, "converge_entry_unit_closed"
        ) as close:
            result, stderr = self.invoke_main()
        self.assertEqual(0, result, stderr)
        self.assertEqual(len(recovery_boot.ENTRY_UNITS), close.call_count)
        self.assertTrue(self.failure_path.is_file())
        self.assertFalse(self.finalizing_path.exists())
        self.assertFalse((self.transaction / "recovery-receipt.json").exists())

    def test_reboot_after_terminal_write_adopts_and_clears_finalizer(self):
        commit = self.commit()
        self.prepare_finalizing(commit)
        self.prepare_completed_archives(commit)
        write_json(
            self.transaction / "recovery-receipt.json", self.receipt(commit)
        )
        with mock.patch.object(
            recovery_boot, "converge_entry_unit_closed"
        ) as close:
            result, stderr = self.invoke_main()
        self.assertEqual(0, result, stderr)
        close.assert_not_called()
        self.assertFalse(self.finalizing_path.exists())
        self.assertFalse(self.failure_path.exists())

    def test_disable_failure_keeps_pending_gate_for_next_boot(self):
        original = {"status": "failed-closed"}
        original_raw = write_json(
            self.transaction / "activation-failed.original.json", original
        )
        pending = {
            "markerSha256": hashlib.sha256(original_raw).hexdigest(),
        }
        pending_raw = write_json(self.pending_path, pending)
        failed = mock.Mock(returncode=1)
        with mock.patch.object(recovery_boot, "ROOT", self.root), mock.patch.object(
            recovery_boot, "PENDING", self.pending_path
        ), mock.patch.object(
            recovery_boot, "FAILURE", self.failure_path
        ), mock.patch.object(
            recovery_boot, "strict", side_effect=unchecked_strict
        ), mock.patch.object(
            recovery_boot, "fsync_directory"
        ), mock.patch.object(recovery_boot.subprocess, "run", return_value=failed):
            with self.assertRaisesRegex(
                recovery_boot.VerificationError, "(?:close|disable)"
            ):
                recovery_boot.contain(pending, pending_raw, self.transaction)
        self.assertTrue(self.pending_path.is_file())

    def test_exact_completion_receipt_consumes_pending(self):
        commit = self.commit()
        self.prepare_pending(commit)
        self.prepare_completed_archives(commit)
        write_json(
            self.transaction / "recovery-receipt.json", self.receipt(commit)
        )
        result, stderr = self.invoke_main()
        self.assertEqual(0, result, stderr)
        self.assertFalse(self.pending_path.exists())

    def test_database_recovery_narrow_receipt_byte_corruption_keeps_boot_gate(self):
        commit = self.commit()
        self.prepare_pending(commit)
        self.prepare_completed_archives(commit)
        write_json(
            self.transaction / "recovery-receipt.json", self.receipt(commit)
        )
        self.database_receipt_path.write_bytes(
            self.database_receipt_path.read_bytes() + b"\n"
        )

        result, stderr = self.invoke_main()

        self.assertEqual(1, result)
        self.assertIn("database recovery receipt digest changed", stderr)
        self.assertTrue(self.pending_path.is_file())

    def test_database_recovery_detail_byte_corruption_keeps_boot_gate(self):
        commit = self.commit()
        self.prepare_pending(commit)
        self.prepare_completed_archives(commit)
        write_json(
            self.transaction / "recovery-receipt.json", self.receipt(commit)
        )
        self.database_detail_fixture.write_bytes(
            self.database_detail_fixture.read_bytes() + b"\n"
        )

        result, stderr = self.invoke_main()

        self.assertEqual(1, result)
        self.assertIn("detailed database recovery receipt digest changed", stderr)
        self.assertTrue(self.pending_path.is_file())

    def test_pending_without_terminal_contains_and_clears_probe_authority(self):
        commit = self.commit()
        self.prepare_pending(commit)
        pending_raw = self.pending_path.read_bytes()
        self.prepare_completed_archives(commit)
        original_path = self.transaction / "activation-failed.original.json"
        original = original_path.read_bytes()
        write_json(self.authorization_path, self.authorization(pending_raw))
        with mock.patch.object(recovery_boot, "converge_entry_unit_closed"):
            result, stderr = self.invoke_main()
        self.assertEqual(0, result, stderr)
        self.assertEqual(original, self.failure_path.read_bytes())
        self.assertFalse(self.authorization_path.exists())
        self.assertFalse(self.pending_path.exists())

    def test_exact_completion_consumes_bound_authorization_then_pending(self):
        commit = self.commit()
        self.prepare_pending(commit)
        pending_raw = self.pending_path.read_bytes()
        self.prepare_completed_archives(commit)
        write_json(
            self.transaction / "recovery-receipt.json", self.receipt(commit)
        )
        write_json(self.authorization_path, self.authorization(pending_raw))
        result, stderr = self.invoke_main()
        self.assertEqual(0, result, stderr)
        self.assertFalse(self.authorization_path.exists())
        self.assertFalse(self.pending_path.exists())

    def test_mismatched_authorization_cannot_clear_exact_terminal_or_pending(self):
        commit = self.commit()
        self.prepare_pending(commit)
        pending_raw = self.pending_path.read_bytes()
        self.prepare_completed_archives(commit)
        write_json(
            self.transaction / "recovery-receipt.json", self.receipt(commit)
        )
        write_json(
            self.authorization_path,
            self.authorization(pending_raw, pending_sha256="f" * 64),
        )
        result, stderr = self.invoke_main()
        self.assertEqual(1, result, stderr)
        self.assertTrue(self.authorization_path.is_file())
        self.assertTrue(self.pending_path.is_file())

    def test_completion_receipt_with_unknown_key_is_rejected_and_retained(self):
        commit = self.commit()
        self.prepare_pending(commit)
        self.prepare_completed_archives(commit)
        receipt = self.receipt(commit)
        receipt["unexpected"] = True
        write_json(self.transaction / "recovery-receipt.json", receipt)
        result, stderr = self.invoke_main()
        self.assertEqual(1, result, stderr)
        self.assertTrue(self.pending_path.is_file())

    def test_completion_receipt_must_equal_commit_authority_fields(self):
        commit = self.commit()
        self.prepare_pending(commit)
        self.prepare_completed_archives(commit)
        receipt = self.receipt(commit)
        receipt["approvalReference"] = "CHG-2026-0812-DIFFERENT"
        write_json(self.transaction / "recovery-receipt.json", receipt)
        result, stderr = self.invoke_main()
        self.assertEqual(1, result, stderr)
        self.assertTrue(self.pending_path.is_file())

    def test_completion_receipt_cannot_clear_pending_without_every_bound_archive(self):
        archive_names = (
            "activation-failed.original.json",
            "recovery-in-progress.completed.json",
            "boot-enablement.recovery.json",
        )
        for missing in archive_names:
            with self.subTest(missing=missing):
                for child in self.transaction.iterdir():
                    child.unlink()
                if self.pending_path.exists():
                    self.pending_path.unlink()
                commit = self.commit()
                self.prepare_pending(commit)
                self.prepare_completed_archives(commit)
                write_json(
                    self.transaction / "recovery-receipt.json",
                    self.receipt(commit),
                )
                (self.transaction / missing).unlink()
                result, stderr = self.invoke_main()
                self.assertEqual(1, result, stderr)
                self.assertTrue(self.pending_path.is_file())

    def test_previous_runtime_commit_is_an_equally_bound_terminal_path(self):
        commit = self.commit()
        commit["action"] = "restore-previous"
        commit["status"] = "previous-runtime-committed-pending-ingress"
        self.prepare_pending(commit)
        self.prepare_completed_archives(commit)
        write_json(
            self.transaction / "recovery-receipt.json", self.receipt(commit)
        )
        result, stderr = self.invoke_main()
        self.assertEqual(0, result, stderr)
        self.assertFalse(self.pending_path.exists())


class RuntimeBootPendingGateTest(unittest.TestCase):
    def test_recovery_ingress_pending_refuses_before_runtime_or_database_reads(self):
        def present(path: Path) -> bool:
            return path == runtime_boot.RECOVERY_INGRESS_PENDING

        with mock.patch.object(runtime_boot.os, "geteuid", return_value=0), mock.patch.object(
            runtime_boot, "_require_root_directory"
        ), mock.patch.object(
            runtime_boot, "_require_root_file"
        ), mock.patch.object(
            runtime_boot, "_lexists", side_effect=present
        ), mock.patch.object(
            runtime_boot,
            "_internal_test_runtime_contract",
            side_effect=AssertionError("runtime reads must not begin while recovery ingress is pending"),
        ):
            with self.assertRaisesRegex(
                runtime_boot.BootVerificationError, "recovery-ingress-pending"
            ):
                runtime_boot.verify_runtime_boot()


class ExistingHostEnvironmentAndLegacyNginxBridgeTest(unittest.TestCase):
    DOMAIN = "imp.internal.example"
    CIDR = "10.23.45.0/24"
    APPROVAL = "CHG-2026-0813-INTERNAL-TEST"
    INTERNAL_ENV = (
        b"UTEN_PROFILE=internal-test\n"
        b"UTEN_LOCAL_ALLOWED_CIDRS=127.0.0.0/8,10.23.45.0/24\n"
        b"UTEN_CORS_ORIGINS=https://imp.internal.example\n"
    )
    PRODUCTION_ENV = b"UTEN_PROFILE=prod\nUTEN_STORAGE_PROVIDER=oss\n"

    def environment_fixture(self, root: Path):
        environment_dir = root / "etc" / "uten-imp"
        environment_dir.mkdir(parents=True)
        environment_dir.chmod(0o755)
        transaction = root / TRANSACTION_ID
        transaction.mkdir(mode=0o700)
        validator = root / "validate-internal-test-server-env"
        validator.write_bytes(b"#!/bin/bash\nexit 0\n")
        validator.chmod(0o700)
        return (
            environment_dir / "server.env",
            environment_dir / "server.env.pending",
            transaction,
            validator,
        )

    def test_reviewed_production_preimage_bridges_to_snapshotted_internal_pending(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            live, pending, transaction, validator = self.environment_fixture(root)
            live.write_bytes(self.PRODUCTION_ENV)
            live.chmod(0o640)
            pending.write_bytes(self.INTERNAL_ENV)
            pending.chmod(0o600)
            old_sha = hashlib.sha256(self.PRODUCTION_ENV).hexdigest()
            new_sha = hashlib.sha256(self.INTERNAL_ENV).hexdigest()
            with mock.patch.object(
                preparer, "SERVER_ENV", live
            ), mock.patch.object(
                preparer, "SERVER_ENV_PENDING", pending
            ), simulated_preparer_root_filesystem() as calls:
                snapshot = preparer.snapshot_server_environment(
                    transaction, new_sha, resume_authorized=False
                )
                result = preparer.install_internal_server_environment(
                    transaction_dir=transaction,
                    snapshot=snapshot,
                    validator=validator,
                    expected_preimage_sha=old_sha,
                    expected_sha=new_sha,
                    domain=self.DOMAIN,
                    cidr=self.CIDR,
                    approval_reference=self.APPROVAL,
                    resume_authorized=False,
                )

            self.assertEqual(self.INTERNAL_ENV, snapshot.read_bytes())
            self.assertEqual(self.INTERNAL_ENV, live.read_bytes())
            self.assertEqual(0o640, stat.S_IMODE(live.stat().st_mode))
            calls.chown.assert_any_call(live, 0, 4242)
            calls.run.assert_called_once_with(
                ["/bin/bash", "--noprofile", "--norc", str(validator), str(snapshot)]
            )
            receipt_path = Path(result["path"])
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            self.assertEqual(self.APPROVAL, receipt["approvalReference"])
            self.assertEqual(old_sha, receipt["oldSha256"])
            self.assertEqual(new_sha, receipt["newSha256"])
            self.assertEqual(
                hashlib.sha256(receipt_path.read_bytes()).hexdigest(),
                result["sha256"],
            )

    def test_live_environment_outside_reviewed_preimage_and_target_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            live, pending, transaction, validator = self.environment_fixture(root)
            unexpected = b"UTEN_PROFILE=unexpected\n"
            live.write_bytes(unexpected)
            live.chmod(0o640)
            pending.write_bytes(self.INTERNAL_ENV)
            pending.chmod(0o600)
            old_sha = hashlib.sha256(self.PRODUCTION_ENV).hexdigest()
            new_sha = hashlib.sha256(self.INTERNAL_ENV).hexdigest()
            with mock.patch.object(
                preparer, "SERVER_ENV", live
            ), mock.patch.object(
                preparer, "SERVER_ENV_PENDING", pending
            ), simulated_preparer_root_filesystem():
                snapshot = preparer.snapshot_server_environment(
                    transaction, new_sha, resume_authorized=False
                )
                with self.assertRaisesRegex(
                    preparer.PreparationError,
                    "neither reviewed preimage nor target",
                ):
                    preparer.install_internal_server_environment(
                        transaction_dir=transaction,
                        snapshot=snapshot,
                        validator=validator,
                        expected_preimage_sha=old_sha,
                        expected_sha=new_sha,
                        domain=self.DOMAIN,
                        cidr=self.CIDR,
                        approval_reference=self.APPROVAL,
                        resume_authorized=False,
                    )

            self.assertEqual(unexpected, live.read_bytes())
            self.assertFalse((transaction / "server-environment-bridge.json").exists())

    def test_pending_environment_symlink_is_rejected_before_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _live, pending, transaction, _validator = self.environment_fixture(root)
            actual = pending.with_name("server.env.pending.actual")
            actual.write_bytes(self.INTERNAL_ENV)
            actual.chmod(0o600)
            try:
                pending.symlink_to(actual)
            except OSError as exc:
                self.skipTest(f"fixture cannot create a symlink: {exc}")
            new_sha = hashlib.sha256(self.INTERNAL_ENV).hexdigest()
            with mock.patch.object(
                preparer, "SERVER_ENV_PENDING", pending
            ), simulated_preparer_root_filesystem():
                with self.assertRaisesRegex(
                    preparer.PreparationError, "unsafe"
                ):
                    preparer.snapshot_server_environment(
                        transaction, new_sha, resume_authorized=False
                    )
            self.assertFalse((transaction / "server.env.snapshot").exists())

    def test_resume_after_target_replace_repairs_metadata_and_keeps_change_approval(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            live, _pending, transaction, validator = self.environment_fixture(root)
            snapshot = transaction / "server.env.snapshot"
            snapshot.write_bytes(self.INTERNAL_ENV)
            snapshot.chmod(0o600)
            # Simulate a crash after atomic replacement but before the final
            # application-group mode repair and terminal receipt publication.
            live.write_bytes(self.INTERNAL_ENV)
            live.chmod(0o600)
            old_sha = hashlib.sha256(self.PRODUCTION_ENV).hexdigest()
            new_sha = hashlib.sha256(self.INTERNAL_ENV).hexdigest()
            with mock.patch.object(
                preparer, "SERVER_ENV", live
            ), simulated_preparer_root_filesystem() as calls:
                with self.assertRaisesRegex(
                    preparer.PreparationError, "bypassed its reviewed preimage"
                ):
                    preparer.install_internal_server_environment(
                        transaction_dir=transaction,
                        snapshot=snapshot,
                        validator=validator,
                        expected_preimage_sha=old_sha,
                        expected_sha=new_sha,
                        domain=self.DOMAIN,
                        cidr=self.CIDR,
                        approval_reference=self.APPROVAL,
                        resume_authorized=False,
                    )
                result = preparer.install_internal_server_environment(
                    transaction_dir=transaction,
                    snapshot=snapshot,
                    validator=validator,
                    expected_preimage_sha=old_sha,
                    expected_sha=new_sha,
                    domain=self.DOMAIN,
                    cidr=self.CIDR,
                    approval_reference=self.APPROVAL,
                    resume_authorized=True,
                )

            self.assertEqual(0o640, stat.S_IMODE(live.stat().st_mode))
            calls.chown.assert_called_once_with(live, 0, 4242)
            receipt = json.loads(Path(result["path"]).read_text(encoding="utf-8"))
            self.assertEqual(self.APPROVAL, receipt["approvalReference"])
            self.assertEqual(
                "COMMITTED_INTERNAL_TEST_ENV_ENTRY_CLOSED", receipt["status"]
            )

    def nginx_fixture(self, root: Path):
        nginx_root = root / "etc" / "nginx"
        live_parent = nginx_root / "conf.d"
        live_parent.mkdir(parents=True)
        live_parent.chmod(0o755)
        transaction = root / TRANSACTION_ID
        transaction.mkdir(mode=0o700)
        return (
            live_parent / "uten-imp.conf",
            nginx_root / "uten-imp-disabled",
            transaction,
        )

    def test_legacy_live_include_is_atomically_archived_and_receipted(self):
        payload = b"upstream legacy_backend { server 127.0.0.1:8080; }\n"
        expected_sha = hashlib.sha256(payload).hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            live, archive_root, transaction = self.nginx_fixture(Path(directory))
            live.write_bytes(payload)
            live.chmod(0o644)
            with mock.patch.object(
                preparer, "LEGACY_NGINX_TARGET", live
            ), mock.patch.object(
                preparer, "LEGACY_NGINX_ARCHIVE_ROOT", archive_root
            ), simulated_preparer_root_filesystem():
                result = preparer.handoff_legacy_nginx(
                    transaction, expected_sha, resume_authorized=False
                )

            archive = archive_root / f"{transaction.name}.conf"
            self.assertFalse(live.exists())
            self.assertEqual(payload, archive.read_bytes())
            self.assertEqual(0o700, stat.S_IMODE(archive_root.stat().st_mode))
            receipt = json.loads(Path(result["path"]).read_text(encoding="utf-8"))
            self.assertEqual(str(archive), receipt["archivePath"])
            self.assertEqual(expected_sha, receipt["archiveSha256"])
            self.assertEqual(expected_sha, receipt["preimageSha256"])

    def test_resume_adopts_exact_archive_left_by_post_rename_crash(self):
        payload = b"server { listen 8080; }\n"
        expected_sha = hashlib.sha256(payload).hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            live, archive_root, transaction = self.nginx_fixture(Path(directory))
            archive_root.mkdir(mode=0o700)
            archive = archive_root / f"{transaction.name}.conf"
            archive.write_bytes(payload)
            archive.chmod(0o644)
            with mock.patch.object(
                preparer, "LEGACY_NGINX_TARGET", live
            ), mock.patch.object(
                preparer, "LEGACY_NGINX_ARCHIVE_ROOT", archive_root
            ), simulated_preparer_root_filesystem():
                with self.assertRaisesRegex(
                    preparer.PreparationError, "bypassed its reviewed live preimage"
                ):
                    preparer.handoff_legacy_nginx(
                        transaction, expected_sha, resume_authorized=False
                    )
                result = preparer.handoff_legacy_nginx(
                    transaction, expected_sha, resume_authorized=True
                )

            self.assertEqual(payload, archive.read_bytes())
            self.assertFalse(live.exists())
            receipt = json.loads(Path(result["path"]).read_text(encoding="utf-8"))
            self.assertEqual(
                "COMMITTED_LEGACY_INCLUDE_DISABLED_ENTRY_CLOSED",
                receipt["status"],
            )

    def test_legacy_handoff_rejects_coexisting_paths_and_wrong_archive_digest(self):
        desired = b"reviewed legacy include\n"
        desired_sha = hashlib.sha256(desired).hexdigest()
        for case in ("coexisting", "wrong-digest"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                live, archive_root, transaction = self.nginx_fixture(Path(directory))
                archive_root.mkdir(mode=0o700)
                archive = archive_root / f"{transaction.name}.conf"
                archive.write_bytes(
                    desired if case == "coexisting" else b"unreviewed archive\n"
                )
                archive.chmod(0o644)
                if case == "coexisting":
                    live.write_bytes(desired)
                    live.chmod(0o644)
                    message = "coexist"
                else:
                    message = "differs from the reviewed preimage"
                with mock.patch.object(
                    preparer, "LEGACY_NGINX_TARGET", live
                ), mock.patch.object(
                    preparer, "LEGACY_NGINX_ARCHIVE_ROOT", archive_root
                ), simulated_preparer_root_filesystem():
                    with self.assertRaisesRegex(preparer.PreparationError, message):
                        preparer.handoff_legacy_nginx(
                            transaction, desired_sha, resume_authorized=True
                        )
                self.assertFalse(
                    (transaction / "legacy-nginx-handoff.json").exists()
                )


class ReviewedHostManifestProducerConsumerTest(unittest.TestCase):
    DOMAIN = "imp.internal.example"
    CIDR = "10.23.45.0/24"
    APPROVAL = "CHG-2026-0813-REVIEW-MANIFEST"
    TLS_SECRET = b"TLS-PRIVATE-MATERIAL-MUST-NOT-LEAK"
    DB_SECRET = b"DB-PASSWORD-MUST-NOT-LEAK"

    def test_real_root_source_digest_rejects_writable_link_and_hash_race(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "reviewed-source"
            source.write_bytes(b"reviewed bytes\n")
            source.chmod(0o600)
            real_fstat = os.fstat
            real_lstat = type(source).lstat

            def root_owned_stat(details):
                return SimpleNamespace(
                    st_ctime_ns=details.st_ctime_ns,
                    st_dev=details.st_dev,
                    st_gid=0,
                    st_ino=details.st_ino,
                    st_mode=details.st_mode,
                    st_mtime_ns=details.st_mtime_ns,
                    st_nlink=details.st_nlink,
                    st_size=details.st_size,
                    st_uid=0,
                )

            def root_owned_fstat(descriptor: int):
                return root_owned_stat(real_fstat(descriptor))

            def root_owned_lstat(path: Path, *args, **kwargs):
                return root_owned_stat(real_lstat(path, *args, **kwargs))

            with mock.patch.object(
                manifest_builder.os, "fstat", side_effect=root_owned_fstat
            ), mock.patch.object(
                type(source),
                "lstat",
                autospec=True,
                side_effect=root_owned_lstat,
            ), mock.patch.object(
                manifest_builder, "_validate_root_parent_chain"
            ):
                self.assertEqual(
                    hashlib.sha256(source.read_bytes()).hexdigest(),
                    manifest_builder.root_source_digest(source, "fixture"),
                )
                source.chmod(0o666)
                with self.assertRaisesRegex(RuntimeError, "immutable|root-owned"):
                    manifest_builder.root_source_digest(source, "fixture")
                source.chmod(0o600)
                link = root / "reviewed-source-link"
                link.symlink_to(source)
                with self.assertRaisesRegex(RuntimeError, "safely|immutable"):
                    manifest_builder.root_source_digest(link, "fixture")

            calls = 0

            def racing_fstat(descriptor: int):
                nonlocal calls
                calls += 1
                details = root_owned_fstat(descriptor)
                if calls == 2:
                    details.st_mtime_ns += 1
                return details

            with mock.patch.object(
                manifest_builder.os, "fstat", side_effect=racing_fstat
            ), mock.patch.object(
                type(source),
                "lstat",
                autospec=True,
                side_effect=root_owned_lstat,
            ), mock.patch.object(
                manifest_builder, "_validate_root_parent_chain"
            ), self.assertRaisesRegex(RuntimeError, "changed while"):
                manifest_builder.root_source_digest(source, "fixture")

    @contextlib.contextmanager
    def fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            desired = root / "reviewed-target-source"
            desired.write_bytes(b"new reviewed executable bytes\n")
            desired.chmod(0o644)
            second_source = root / "second-source"
            second_source.write_bytes(b"second reviewed source\n")
            second_source.chmod(0o644)
            nginx_source = root / "nginx-template"
            nginx_source.write_bytes(b"reviewed nginx template\n")
            nginx_source.chmod(0o644)
            live_target = root / "installed-target"
            live_target.write_bytes(b"LEGACY=" + self.DB_SECRET + b"\n")
            live_target.chmod(0o644)
            absent_target = root / "absent-target"
            nginx_target = root / "live-nginx"
            nginx_target.write_bytes(b"legacy live nginx\n")
            nginx_target.chmod(0o644)
            legacy_nginx = root / "legacy-nginx"
            legacy_nginx.write_bytes(b"legacy phase4 nginx\n")
            legacy_nginx.chmod(0o644)
            cert = root / "tls.crt"
            cert.write_bytes(b"certificate bytes\n")
            cert.chmod(0o644)
            key = root / "tls.key"
            key.write_bytes(self.TLS_SECRET + b"\n")
            key.chmod(0o600)
            sources = {
                "fixtureTargetSha256": desired,
                "secondSourceSha256": second_source,
            }
            targets = {
                "fixtureTargetSha256": live_target,
                "absentTargetSha256": absent_target,
            }
            now = datetime.now(timezone.utc).replace(microsecond=0)
            created = (now - timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
            expires = (now + timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
            preparer_sha = preparer.sha256_file(
                SETUP_DIR / "prepare-existing-test-host-internal-runtime.py"
            )
            builder_sha = preparer.sha256_file(
                SETUP_DIR / "build-internal-test-reviewed-host-manifest.py"
            )
            args = SimpleNamespace(
                allowed_signers_sha256="1" * 64,
                approval_reference=self.APPROVAL,
                created_at_utc=created,
                domain=self.DOMAIN,
                expected_builder_sha256=builder_sha,
                expected_nginx_expanded_config_sha256="5" * 64,
                expected_preparer_sha256=preparer_sha,
                expires_at_utc=expires,
                office_cidr=self.CIDR,
                server_environment_preimage_sha256="2" * 64,
                server_environment_sha256="3" * 64,
                tls_cert=cert,
                tls_key=key,
                updater_venv_inventory_sha256="4" * 64,
            )
            with contextlib.ExitStack() as stack:
                stack.enter_context(
                    mock.patch.object(manifest_builder.os, "geteuid", return_value=0)
                )
                stack.enter_context(
                    mock.patch.object(
                        manifest_builder,
                        "root_source_digest",
                        side_effect=simulated_root_source_digest,
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        manifest_builder,
                        "stable_root_source",
                        side_effect=simulated_stable_root_source,
                    )
                )
                load_preparer = stack.enter_context(
                    mock.patch.object(
                        manifest_builder, "load_preparer", return_value=preparer
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        manifest_builder,
                        "PREPARER",
                        SETUP_DIR / "prepare-existing-test-host-internal-runtime.py",
                    )
                )
                for name, value in (
                    ("SOURCES", sources),
                    ("TARGETS", targets),
                    ("TRUSTED_INSTALLER_SOURCE_KEYS", frozenset()),
                    (
                        "TRUSTED_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEYS",
                        frozenset(),
                    ),
                    ("NGINX_SOURCE", nginx_source),
                    ("NGINX_TARGET", nginx_target),
                    ("LEGACY_NGINX_TARGET", legacy_nginx),
                    ("TLS_ROOT", cert.parent),
                ):
                    stack.enter_context(mock.patch.object(preparer, name, value))
                stack.enter_context(
                    mock.patch.object(
                        preparer,
                        "validate_trusted_installer_source_payloads",
                        return_value={},
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        preparer,
                        "trusted_installer_target_preimages",
                        return_value={},
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        preparer, "root_file", side_effect=simulated_root_file
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        preparer,
                        "stable_root_digest",
                        side_effect=simulated_stable_root_digest,
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        preparer,
                        "root_directory",
                        side_effect=simulated_root_directory,
                    )
                )
                entry_closed = stack.enter_context(
                    mock.patch.object(preparer, "entry_closed")
                )
                validate_inputs = stack.enter_context(
                    mock.patch.object(preparer, "validate_network_inputs")
                )
                stack.enter_context(
                    mock.patch.object(manifest_builder, "validate_tls_snapshot")
                )
                prospective_nginx = stack.enter_context(
                    mock.patch.object(
                        preparer,
                        "prospective_nginx_expanded",
                        return_value=b"5" * 32,
                    )
                )
                args.expected_nginx_expanded_config_sha256 = hashlib.sha256(
                    b"5" * 32
                ).hexdigest()
                atomic = stack.enter_context(mock.patch.object(preparer, "atomic"))
                yield SimpleNamespace(
                    args=args,
                    atomic=atomic,
                    desired=desired,
                    entry_closed=entry_closed,
                    live_target=live_target,
                    load_preparer=load_preparer,
                    nginx_source=nginx_source,
                    prospective_nginx=prospective_nginx,
                    sources=sources,
                    targets=targets,
                    validate_inputs=validate_inputs,
                )

    @staticmethod
    def consumer_args(producer_args, manifest: Path, manifest_sha: str):
        return SimpleNamespace(
            allowed_signers_sha256=producer_args.allowed_signers_sha256,
            approval_reference=producer_args.approval_reference,
            domain=producer_args.domain,
            expected_allowed_signers_sha256=producer_args.allowed_signers_sha256,
            expected_preparer_sha256=producer_args.expected_preparer_sha256,
            expected_nginx_expanded_config_sha256=(
                producer_args.expected_nginx_expanded_config_sha256
            ),
            expected_server_environment_preimage_sha256=(
                producer_args.server_environment_preimage_sha256
            ),
            expected_server_environment_sha256=(
                producer_args.server_environment_sha256
            ),
            expected_source_manifest_sha256=manifest_sha,
            expected_updater_venv_inventory_sha256=(
                producer_args.updater_venv_inventory_sha256
            ),
            office_cidr=producer_args.office_cidr,
            source_manifest=manifest,
            tls_cert=producer_args.tls_cert,
            tls_key=producer_args.tls_key,
        )

    def test_canonical_producer_bytes_are_accepted_by_preparer_and_hide_secrets(self):
        with self.fixture() as fixture:
            payload = manifest_builder.build(fixture.args)
            parsed = preparer.strict_json_document(
                payload, "reviewed manifest producer output"
            )
            self.assertEqual(preparer.canonical(parsed), payload)
            self.assertNotIn(self.TLS_SECRET, payload)
            self.assertNotIn(self.DB_SECRET, payload)
            self.assertEqual(
                fixture.args.expected_builder_sha256,
                parsed["builderSha256"],
            )
            self.assertEqual(
                fixture.args.expected_builder_sha256,
                parsed["sourceSha256"]["manifestBuilderSha256"],
            )
            self.assertEqual(
                fixture.args.expected_nginx_expanded_config_sha256,
                parsed["hostParameters"][
                    "expectedNginxExpandedConfigSha256"
                ],
            )
            self.assertEqual(
                preparer.sha256_file(fixture.live_target),
                parsed["targetPreimageSha256"]["fixtureTargetSha256"],
            )
            self.assertIsNone(
                parsed["targetPreimageSha256"]["absentTargetSha256"]
            )

            manifest = Path(fixture.live_target.parent) / "reviewed-host.json"
            manifest.write_bytes(payload)
            manifest.chmod(0o600)
            digest = hashlib.sha256(payload).hexdigest()
            accepted, accepted_sha = preparer.reviewed_source_manifest(
                self.consumer_args(fixture.args, manifest, digest)
            )
            self.assertEqual(parsed, accepted)
            self.assertEqual(digest, accepted_sha)
            fixture.entry_closed.assert_called_once_with()
            fixture.validate_inputs.assert_called_once_with(
                self.DOMAIN,
                self.CIDR,
            )
            fixture.prospective_nginx.assert_called_once_with(
                self.DOMAIN,
                self.CIDR,
                fixture.args.tls_cert,
                fixture.args.tls_key,
                fixture.nginx_source.read_bytes(),
            )
            fixture.atomic.assert_not_called()

    def test_source_or_target_drift_cannot_reuse_reviewed_bytes(self):
        with self.fixture() as fixture:
            payload = manifest_builder.build(fixture.args)
            manifest = fixture.live_target.parent / "reviewed-host.json"
            manifest.write_bytes(payload)
            manifest.chmod(0o600)
            digest = hashlib.sha256(payload).hexdigest()
            original_source = fixture.desired.read_bytes()
            fixture.desired.write_bytes(original_source + b"drift\n")
            with self.assertRaisesRegex(
                preparer.PreparationError, "exact source inventory"
            ):
                preparer.reviewed_source_manifest(
                    self.consumer_args(fixture.args, manifest, digest)
                )

            fixture.desired.write_bytes(original_source)
            reviewed = json.loads(payload.decode("utf-8"))
            reviewed_preimage = reviewed["targetPreimageSha256"][
                "fixtureTargetSha256"
            ]
            fixture.live_target.write_bytes(b"unreviewed live target drift\n")
            with self.assertRaisesRegex(
                preparer.PreparationError, "differs from both authorized preimage"
            ):
                preparer.install_source(
                    fixture.desired,
                    fixture.live_target,
                    0o644,
                    reviewed_preimage,
                )
            fixture.atomic.assert_not_called()

    def test_mutable_or_symlink_source_is_rejected_before_hashing(self):
        for case in (
            "mutable-source",
            "symlink-source",
            "mutable-nginx",
            "symlink-nginx",
            "mutable-preparer",
            "symlink-preparer",
        ):
            with self.subTest(case=case), self.fixture() as fixture:
                preparer_override = None
                if case == "mutable-source":
                    fixture.desired.chmod(0o666)
                elif case == "symlink-source":
                    link = fixture.desired.parent / "untrusted-source-link"
                    link.symlink_to(fixture.desired)
                    fixture.sources["fixtureTargetSha256"] = link
                elif case == "mutable-nginx":
                    fixture.nginx_source.chmod(0o666)
                elif case == "symlink-nginx":
                    link = fixture.nginx_source.parent / "untrusted-nginx-link"
                    link.symlink_to(fixture.nginx_source)
                    preparer_override = mock.patch.object(
                        preparer, "NGINX_SOURCE", link
                    )
                else:
                    copied = fixture.desired.parent / "preparer-copy.py"
                    copied.write_bytes(
                        (SETUP_DIR / "prepare-existing-test-host-internal-runtime.py").read_bytes()
                    )
                    copied.chmod(0o666 if case == "mutable-preparer" else 0o600)
                    candidate = copied
                    if case == "symlink-preparer":
                        candidate = fixture.desired.parent / "preparer-link.py"
                        candidate.symlink_to(copied)
                    fixture.args.expected_preparer_sha256 = preparer.sha256_file(copied)
                    preparer_override = mock.patch.object(
                        manifest_builder, "PREPARER", candidate
                    )
                with contextlib.ExitStack() as stack:
                    if preparer_override is not None:
                        stack.enter_context(preparer_override)
                    with self.assertRaisesRegex(
                        RuntimeError, "root-controlled|root-owned|unsafe"
                    ):
                        manifest_builder.build(fixture.args)
                if case in {"mutable-preparer", "symlink-preparer"}:
                    fixture.load_preparer.assert_not_called()
                fixture.atomic.assert_not_called()

    def test_nonroot_entry_open_and_expired_or_long_windows_are_rejected(self):
        with self.fixture() as fixture:
            with mock.patch.object(
                manifest_builder.os, "geteuid", return_value=1000
            ), mock.patch.object(
                manifest_builder, "load_preparer"
            ) as load:
                with self.assertRaisesRegex(RuntimeError, "run as root"):
                    manifest_builder.build(fixture.args)
                load.assert_not_called()

            fixture.entry_closed.side_effect = preparer.PreparationError(
                "employee entry remains open"
            )
            with self.assertRaisesRegex(
                preparer.PreparationError, "entry remains open"
            ):
                manifest_builder.build(fixture.args)
            fixture.entry_closed.side_effect = None

            expired = SimpleNamespace(
                **{
                    **vars(fixture.args),
                    "created_at_utc": "2026-01-01T00:00:00Z",
                    "expires_at_utc": "2026-01-02T00:00:00Z",
                }
            )
            with self.assertRaisesRegex(
                RuntimeError, "expired|stale|validity|window"
            ):
                manifest_builder.build(expired)

            now = datetime.now(timezone.utc).replace(microsecond=0)
            not_yet_valid = SimpleNamespace(
                **{
                    **vars(fixture.args),
                    "created_at_utc": (
                        now + timedelta(hours=1)
                    ).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "expires_at_utc": (
                        now + timedelta(hours=2)
                    ).strftime("%Y-%m-%dT%H:%M:%SZ"),
                }
            )
            with self.assertRaisesRegex(
                RuntimeError, "future|not yet|chronology|validity|window"
            ):
                manifest_builder.build(not_yet_valid)

            excessive = SimpleNamespace(
                **{
                    **vars(fixture.args),
                    "created_at_utc": "2026-08-13T00:00:00Z",
                    "expires_at_utc": "2026-08-21T00:00:01Z",
                }
            )
            with self.assertRaisesRegex(RuntimeError, "seven days"):
                manifest_builder.build(excessive)
            fixture.atomic.assert_not_called()


class ExistingHostSameTransactionTerminalTest(unittest.TestCase):
    DOMAIN = "imp.internal.example"
    CIDR = "10.23.45.0/24"
    APPROVAL = "CHG-2026-0813-HOST-TERMINAL"

    @contextlib.contextmanager
    def fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "host-preparation-evidence"
            evidence.mkdir(mode=0o700)
            active_path = root / "active.json"
            contract_path = root / "internal-test-runtime-contract.json"
            mutation_active = root / "mutation-authorized.json"
            server_env = root / "server.env"
            server_env.write_bytes(
                b"UTEN_PROFILE=internal-test\n"
                b"UTEN_LOCAL_ALLOWED_CIDRS=127.0.0.0/8,10.23.45.0/24\n"
                b"UTEN_CORS_ORIGINS=https://imp.internal.example\n"
            )
            server_env.chmod(0o640)
            cert = root / "tls.crt"
            key = root / "tls.key"
            cert.write_bytes(b"reviewed certificate bytes\n")
            key.write_bytes(b"reviewed private key bytes\n")
            cert.chmod(0o644)
            key.chmod(0o600)
            expanded_nginx = b"# exact expanded internal nginx config\n"
            expected_expanded_nginx_sha = hashlib.sha256(
                expanded_nginx
            ).hexdigest()

            source = root / "source.py"
            source.write_bytes(b"# reviewed source bytes\n")
            source.chmod(0o644)
            nginx_source = root / "nginx.template"
            nginx_source.write_bytes(b"# reviewed nginx template\n")
            nginx_source.chmod(0o644)
            migrator_validator = root / "validate-migrator-env"
            migrator_validator.write_bytes(b"#!/bin/sh\nexit 0\n")
            migrator_validator.chmod(0o755)
            fixed_target = root / "fixed-target.py"
            fixed_target.write_bytes(b"# installed reviewed target\n")
            fixed_target.chmod(0o644)
            targets = {
                "migratorEnvironmentValidatorSha256": migrator_validator,
                "fixtureTargetSha256": fixed_target,
            }
            sources = {"fixtureSourceSha256": source}

            allowed_signers_sha = "1" * 64
            venv_inventory_sha = "2" * 64
            target_environment_sha = preparer.sha256_file(server_env)
            source_manifest = root / "reviewed-source-manifest.json"
            reviewed = {
                "approvalReference": self.APPROVAL,
                "builderSha256": preparer.sha256_file(
                    SETUP_DIR / "build-internal-test-reviewed-host-manifest.py"
                ),
                "createdAtUtc": "2026-08-13T07:00:00Z",
                "expiresAtUtc": "2026-08-14T07:00:00Z",
                "hostParameters": {
                    "allowedSignersSha256": allowed_signers_sha,
                    "domain": self.DOMAIN,
                    "expectedNginxExpandedConfigSha256": (
                        expected_expanded_nginx_sha
                    ),
                    "officeCidr": self.CIDR,
                    "serverEnvironmentPreimageSha256": "3" * 64,
                    "serverEnvironmentSha256": target_environment_sha,
                    "tlsCertificateSha256": preparer.sha256_file(cert),
                    "tlsKeySha256": preparer.sha256_file(key),
                    "updaterVenvInventorySha256": venv_inventory_sha,
                },
                "kind": "uten-imp-internal-test-reviewed-host-sources",
                "preparerSha256": preparer.sha256_file(
                    SETUP_DIR / "prepare-existing-test-host-internal-runtime.py"
                ),
                "schemaVersion": 1,
                "sourceSha256": {
                    "fixtureSourceSha256": preparer.sha256_file(source),
                    "manifestBuilderSha256": preparer.sha256_file(
                        SETUP_DIR
                        / "build-internal-test-reviewed-host-manifest.py"
                    ),
                    "nginxTemplateSha256": preparer.sha256_file(nginx_source),
                },
                "targetPreimageSha256": {
                    **{key: None for key in targets},
                    "legacyNginxConfigSha256": None,
                    "nginxConfigSha256": None,
                },
            }
            source_manifest_raw = write_json(source_manifest, reviewed)
            source_manifest.chmod(0o600)
            reviewed_sha = hashlib.sha256(source_manifest_raw).hexdigest()
            transaction_id = "prepare-internal-runtime-" + reviewed_sha[:16]
            transaction = evidence / transaction_id
            transaction.mkdir(mode=0o700)
            reviewed_snapshot = transaction / "reviewed-source-manifest.json"
            reviewed_snapshot.write_bytes(source_manifest_raw)
            reviewed_snapshot.chmod(0o600)
            source_snapshot = transaction / "source-snapshot"
            source_snapshot.mkdir(mode=0o700)
            for key_name, source_path in (
                ("fixtureSourceSha256", source),
                (
                    "manifestBuilderSha256",
                    SETUP_DIR
                    / "build-internal-test-reviewed-host-manifest.py",
                ),
                ("nginxTemplateSha256", nginx_source),
            ):
                snapshot_path = source_snapshot / key_name
                snapshot_path.write_bytes(source_path.read_bytes())
                snapshot_path.chmod(0o600)

            args = SimpleNamespace(
                approval_reference=self.APPROVAL,
                domain=self.DOMAIN,
                expected_allowed_signers_sha256=allowed_signers_sha,
                expected_nginx_expanded_config_sha256=(
                    expected_expanded_nginx_sha
                ),
                expected_preparer_sha256=reviewed["preparerSha256"],
                expected_server_environment_preimage_sha256="3" * 64,
                expected_server_environment_sha256=target_environment_sha,
                expected_source_manifest_sha256=reviewed_sha,
                expected_updater_venv_inventory_sha256=venv_inventory_sha,
                office_cidr=self.CIDR,
                source_manifest=source_manifest,
                tls_cert=cert,
                tls_key=key,
            )
            plan = {
                "approvalReference": self.APPROVAL,
                "entryEnabled": False,
                "expectedPreparerSha256": args.expected_preparer_sha256,
                "kind": "uten-imp-internal-test-host-preparation-plan",
                "parameters": {
                    "allowedSignersSha256": allowed_signers_sha,
                    "domain": self.DOMAIN,
                    "expectedNginxExpandedConfigSha256": (
                        expected_expanded_nginx_sha
                    ),
                    "officeCidr": self.CIDR,
                    "serverEnvironmentPreimageSha256": (
                        args.expected_server_environment_preimage_sha256
                    ),
                    "serverEnvironmentSha256": target_environment_sha,
                    "tlsCertificateSha256": preparer.sha256_file(cert),
                    "tlsKeySha256": preparer.sha256_file(key),
                    "updaterVenvInventorySha256": venv_inventory_sha,
                },
                "reviewedSourceManifestSha256": reviewed_sha,
                "reviewedSourceManifestPath": str(reviewed_snapshot),
                "schemaVersion": 1,
                "sourceSha256": reviewed["sourceSha256"],
                "sourceSnapshotPath": str(source_snapshot),
                "status": "APPROVED_ENTRY_CLOSED",
                "targetPreimageSha256": reviewed["targetPreimageSha256"],
                "transactionId": transaction_id,
            }
            plan_path = transaction / "plan.json"
            write_json(plan_path, plan)
            plan_path.chmod(0o600)
            plan_sha = preparer.sha256_file(plan_path)
            authority = {
                "authorizedAtUtc": "2026-08-13T07:01:00Z",
                "kind": "uten-imp-internal-test-host-mutation-authority",
                "planPath": str(plan_path),
                "planSha256": plan_sha,
                "reviewedSourceManifestSha256": reviewed_sha,
                "schemaVersion": 1,
                "snapshotInventorySha256": hashlib.sha256(
                    canonical_bytes(reviewed["sourceSha256"])
                ).hexdigest(),
                "status": "MUTATION_AUTHORIZED_ENTRY_CLOSED",
                "transactionId": transaction_id,
            }
            authority_path = transaction / "mutation-authorized.committed.json"
            write_json(authority_path, authority)
            authority_path.chmod(0o600)

            nginx_target = root / "uten-imp-internal-test.conf"
            nginx_target.write_bytes(b"# exact internal nginx config\n")
            nginx_target.chmod(0o644)
            nginx_link = root / "uten-imp-internal-test.enabled.conf"
            try:
                nginx_link.symlink_to(nginx_target)
            except OSError as exc:
                self.skipTest(f"fixture cannot create a symlink: {exc}")
            prerequisite = {
                "allowedSignersSha256": allowed_signers_sha,
                "updaterVenvInventorySha256": venv_inventory_sha,
            }
            contract = {
                "contractId": "uten-imp-internal-test-runtime-v1",
                "deploymentProfile": "internal-test-local-v1",
                "internalDomain": self.DOMAIN,
                "nginxConfigSha256": preparer.sha256_file(nginx_target),
                "nginxExpandedConfigSha256": expected_expanded_nginx_sha,
                "serverEnvironmentSha256": target_environment_sha,
                "tlsCertificatePath": str(cert),
                "tlsCertificateSha256": preparer.sha256_file(cert),
                "tlsKeyPath": str(key),
                "tlsKeySha256": preparer.sha256_file(key),
                "updaterAllowedSignersSha256": allowed_signers_sha,
                "updaterVenvInventorySha256": venv_inventory_sha,
                **{
                    key: preparer.sha256_file(path)
                    for key, path in targets.items()
                },
            }
            write_json(contract_path, contract)
            contract_path.chmod(0o600)
            receipt = {
                "contractSha256": preparer.sha256_file(contract_path),
                "entryEnabled": False,
                "kind": "uten-imp-internal-test-host-preparation-receipt",
                "mutationAuthorityPath": str(authority_path),
                "mutationAuthoritySha256": preparer.sha256_file(authority_path),
                "nginxEnabledLink": str(nginx_link),
                "nginxEnabledTargetSha256": preparer.sha256_file(nginx_target),
                "planSha256": plan_sha,
                "productionAuthority": False,
                "schemaVersion": 1,
                "status": "COMMITTED_ENTRY_CLOSED",
                "transactionId": transaction_id,
            }
            complete_path = transaction / "complete.json"
            write_json(complete_path, receipt)
            complete_path.chmod(0o600)
            write_json(active_path, receipt)
            active_path.chmod(0o600)

            # Prove a completed same-transaction host validation does not
            # demand an empty downstream commissioning evidence root.
            downstream = evidence / "internal-test-db-existing-evidence"
            downstream.mkdir(mode=0o700)
            write_json(downstream / "complete.json", {"status": "non-empty"})

            migrator_env = root / "migrator.env"
            migrator_env.write_bytes(b"PGPASSWORD=fixture\n")
            migrator_env.chmod(0o640)
            no_write = mock.Mock(
                side_effect=AssertionError(
                    "terminal same-transaction validation attempted a write"
                )
            )
            run_result = subprocess.CompletedProcess([], 0, b"", b"")
            with contextlib.ExitStack() as stack:
                for name, value in (
                    ("ACTIVE", active_path),
                    ("CONTRACT", contract_path),
                    ("EVIDENCE", evidence),
                    ("MIGRATOR_ENV", migrator_env),
                    ("MUTATION_ACTIVE", mutation_active),
                    ("NGINX_LINK", nginx_link),
                    ("NGINX_SOURCE", nginx_source),
                    ("NGINX_TARGET", nginx_target),
                    ("SERVER_ENV", server_env),
                    ("SOURCES", sources),
                    ("TARGETS", targets),
                    ("TRUSTED_INSTALLER_SOURCE_KEYS", frozenset()),
                    (
                        "TRUSTED_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEYS",
                        frozenset(),
                    ),
                ):
                    stack.enter_context(mock.patch.object(preparer, name, value))
                stack.enter_context(
                    mock.patch.object(
                        preparer,
                        "capture_trusted_installer_snapshot_payloads",
                        return_value={},
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        preparer,
                        "validate_trusted_installer_live_contracts",
                        return_value={},
                    )
                )
                stack.enter_context(
                    mock.patch.object(preparer.os, "geteuid", return_value=0)
                )
                stack.enter_context(
                    mock.patch.object(
                        preparer, "root_file", side_effect=simulated_root_file
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        preparer,
                        "stable_root_digest",
                        side_effect=simulated_stable_root_digest,
                    )
                )
                stack.enter_context(
                    mock.patch.object(
                        preparer,
                        "root_directory",
                        side_effect=simulated_root_directory,
                    )
                )
                validate_inputs = stack.enter_context(
                    mock.patch.object(preparer, "validate_inputs")
                )
                entry_closed = stack.enter_context(
                    mock.patch.object(preparer, "entry_closed")
                )
                prerequisites = stack.enter_context(
                    mock.patch.object(
                        preparer,
                        "validate_common_updater_prerequisites",
                        return_value=prerequisite,
                    )
                )
                nginx_check = stack.enter_context(
                    mock.patch.object(
                        preparer,
                        "unique_nginx_include",
                        return_value=expanded_nginx,
                    )
                )
                run = stack.enter_context(
                    mock.patch.object(preparer, "run", return_value=run_result)
                )
                for name in (
                    "atomic",
                    "handoff_legacy_nginx",
                    "install_source",
                    "snapshot_sources",
                ):
                    stack.enter_context(mock.patch.object(preparer, name, no_write))
                stack.enter_context(
                    mock.patch.object(preparer.os, "chown", no_write, create=True)
                )
                stack.enter_context(
                    mock.patch.object(preparer.os, "chmod", no_write, create=True)
                )
                yield SimpleNamespace(
                    active_path=active_path,
                    args=args,
                    authority=authority,
                    authority_path=authority_path,
                    complete_path=complete_path,
                    contract=contract,
                    contract_path=contract_path,
                    entry_closed=entry_closed,
                    evidence=evidence,
                    fixed_target=fixed_target,
                    mutation_active=mutation_active,
                    nginx_check=nginx_check,
                    no_write=no_write,
                    plan=plan,
                    plan_path=plan_path,
                    prerequisites=prerequisites,
                    receipt=receipt,
                    run=run,
                    reviewed_snapshot=reviewed_snapshot,
                    source_manifest=source_manifest,
                    transaction=transaction,
                    transaction_id=transaction_id,
                    validate_inputs=validate_inputs,
                )

    def test_exact_terminal_same_transaction_is_read_only_with_nonempty_db_evidence(self):
        with self.fixture() as fixture:
            result = preparer._apply_locked(fixture.args)

            self.assertEqual(fixture.receipt, result)
            fixture.no_write.assert_not_called()
            fixture.entry_closed.assert_called_once_with()
            fixture.validate_inputs.assert_called_once_with(
                self.DOMAIN,
                self.CIDR,
                fixture.args.tls_cert,
                fixture.args.tls_key,
            )
            fixture.prerequisites.assert_called_once_with()
            fixture.nginx_check.assert_called_once_with()
            fixture.run.assert_called_once()

    def test_preparer_terminal_is_a_commissioner_consumable_golden(self):
        with self.fixture() as fixture, mock.patch.object(
            commissioner, "HOST_PREPARATION_EVIDENCE", fixture.evidence
        ), mock.patch.object(
            commissioner, "HOST_PREPARATION_ACTIVE", fixture.active_path
        ), mock.patch.object(
            commissioner,
            "HOST_PREPARATION_MUTATION_ACTIVE",
            fixture.mutation_active,
        ), mock.patch.object(
            commissioner, "require_root_file"
        ), mock.patch.object(
            commissioner, "require_root_directory"
        ):
            consumed = commissioner.validate_host_preparation_terminal(
                fixture.receipt["contractSha256"]
            )

        self.assertEqual(fixture.receipt, consumed)

    def test_terminal_drift_refuses_before_any_mutation(self):
        cases = (
            "another-transaction",
            "approval-parameter",
            "source-manifest-bytes",
            "plan-bytes",
            "authority-bytes",
            "contract-semantics",
            "contract-domain",
            "contract-tls-path",
            "contract-expanded-graph",
            "target-bytes",
        )
        for case in cases:
            with self.subTest(case=case), self.fixture() as fixture:
                if case == "another-transaction":
                    changed = {
                        **fixture.receipt,
                        "transactionId": "prepare-internal-runtime-" + "f" * 16,
                    }
                    write_json(fixture.active_path, changed)
                    write_json(fixture.complete_path, changed)
                elif case == "approval-parameter":
                    fixture.args.approval_reference = "CHG-2026-0813-DIFFERENT"
                elif case == "source-manifest-bytes":
                    fixture.reviewed_snapshot.write_bytes(
                        fixture.reviewed_snapshot.read_bytes() + b"\n"
                    )
                elif case == "plan-bytes":
                    fixture.plan_path.write_bytes(
                        fixture.plan_path.read_bytes() + b"\n"
                    )
                elif case == "authority-bytes":
                    changed = {
                        **fixture.authority,
                        "authorizedAtUtc": "2026-08-13T07:02:00Z",
                    }
                    write_json(fixture.authority_path, changed)
                elif case.startswith("contract-"):
                    changed_contract = dict(fixture.contract)
                    if case == "contract-semantics":
                        changed_contract["deploymentProfile"] = "production"
                    elif case == "contract-domain":
                        changed_contract["internalDomain"] = "other.internal.example"
                    elif case == "contract-tls-path":
                        changed_contract["tlsKeyPath"] = "/tmp/unreviewed.key"
                    else:
                        changed_contract["nginxExpandedConfigSha256"] = "6" * 64
                    write_json(fixture.contract_path, changed_contract)
                    changed_receipt = {
                        **fixture.receipt,
                        "contractSha256": preparer.sha256_file(
                            fixture.contract_path
                        ),
                    }
                    write_json(fixture.active_path, changed_receipt)
                    write_json(fixture.complete_path, changed_receipt)
                elif case == "target-bytes":
                    fixture.fixed_target.write_bytes(
                        fixture.fixed_target.read_bytes() + b"# drift\n"
                    )

                with self.assertRaises(preparer.PreparationError):
                    preparer._apply_locked(fixture.args)
            fixture.no_write.assert_not_called()


class ExpandedNginxParserBoundaryTest(unittest.TestCase):
    def test_same_line_forwarding_alias_cannot_escape_expanded_config_review(self):
        """Nginx permits several directives on one physical source line.

        Both the enabled-include prefilter and the authoritative ``nginx -T``
        review must therefore reason about directives, not line beginnings.
        Otherwise an unrelated server block can acquire a local backend path
        while evading the exact listener/server/forwarding inventory.
        """

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            confd = root / "conf.d"
            enabled = root / "sites-enabled"
            available = root / "sites-available"
            for path in (confd, enabled, available):
                path.mkdir()
            target = available / "uten-imp-internal-test.conf"
            template = (
                PROJECT_ROOT
                / "deploy/nginx/uten-imp-internal-test.conf.example"
            ).read_text(encoding="utf-8")
            rendered = (
                template.replace("__INTERNAL_DOMAIN__", "erp.internal.example")
                .replace("__EXACT_OFFICE_CIDR__", "10.23.44.0/24")
                .replace(
                    "__INTERNAL_TLS_CERT_PATH__",
                    "/etc/uten-imp/tls/internal.crt",
                )
                .replace(
                    "__INTERNAL_TLS_KEY_PATH__",
                    "/etc/uten-imp/tls/internal.key",
                )
            )
            target.write_text(rendered, encoding="utf-8")
            link = enabled / "uten-imp-internal-test.conf"
            link.symlink_to(target)
            bypass = confd / "unrelated-static.conf"
            bypass_line = (
                "server { listen 8099; "
                "proxy_pass http://127.0.0.1:8080; }\n"
            )
            bypass.write_text(bypass_line, encoding="utf-8")

            real_path = preparer.Path
            real_lstat = type(target).lstat

            def root_owned_lstat(path: Path, *args, **kwargs):
                details = real_lstat(path, *args, **kwargs)
                return SimpleNamespace(
                    st_mode=details.st_mode,
                    st_uid=0,
                    st_gid=0,
                    st_nlink=details.st_nlink,
                    st_dev=details.st_dev,
                    st_ino=details.st_ino,
                    st_size=details.st_size,
                    st_mtime_ns=details.st_mtime_ns,
                    st_ctime_ns=details.st_ctime_ns,
                )

            def mapped_path(value):
                path = real_path(value)
                if path == real_path("/etc/nginx/conf.d"):
                    return confd
                if path == real_path("/etc/nginx/sites-enabled"):
                    return enabled
                return path

            expanded = (rendered + "\n" + bypass_line).encode("utf-8")
            with mock.patch.object(
                preparer, "NGINX_TARGET", target
            ), mock.patch.object(
                preparer, "NGINX_LINK", link
            ), mock.patch.object(
                preparer, "Path", side_effect=mapped_path
            ), mock.patch.object(
                preparer, "root_file"
            ), mock.patch.object(
                preparer, "root_directory"
            ), mock.patch.object(
                type(target),
                "lstat",
                autospec=True,
                side_effect=root_owned_lstat,
            ), mock.patch.object(
                preparer,
                "run",
                return_value=SimpleNamespace(stdout=expanded),
            ) as nginx_t, self.assertRaisesRegex(
                preparer.PreparationError,
                "forwarding boundary|another Uten entry|unreviewed Nginx include",
            ):
                preparer.unique_nginx_include()
            nginx_t.assert_not_called()


class StableTlsReadRaceContractTest(unittest.TestCase):
    class RootStat:
        def __init__(self, details):
            self._details = details
            self.st_uid = 0
            self.st_gid = 0

        def __getattr__(self, name):
            return getattr(self._details, name)

    def assert_path_swap_is_rejected(self, module, reader, error, root_check):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tls.crt"
            path.write_bytes(b"reviewed certificate bytes\n")
            path.chmod(0o644)
            replacement = path.parent / ".tls.crt.replacement"
            replacement.write_bytes(b"unreviewed certificate bytes\n")
            replacement.chmod(0o644)

            real_read = os.read
            real_fstat = os.fstat
            real_lstat = type(path).lstat
            swapped = False

            def root_fstat(descriptor):
                return self.RootStat(real_fstat(descriptor))

            def root_lstat(subject, *args, **kwargs):
                return self.RootStat(real_lstat(subject, *args, **kwargs))

            def swap_after_first_read(descriptor, amount):
                nonlocal swapped
                block = real_read(descriptor, amount)
                if block and not swapped:
                    swapped = True
                    os.replace(replacement, path)
                return block

            with mock.patch.object(
                module, root_check
            ), mock.patch.object(
                module.os, "fstat", side_effect=root_fstat
            ), mock.patch.object(
                type(path), "lstat", autospec=True, side_effect=root_lstat
            ), mock.patch.object(
                module.os, "read", side_effect=swap_after_first_read
            ), self.assertRaisesRegex(error, "changed while|stable"):
                reader(path)
            self.assertTrue(swapped)
            self.assertEqual(b"unreviewed certificate bytes\n", path.read_bytes())

    def test_updater_and_boot_gate_reject_same_path_rename_during_tls_read(self):
        self.assert_path_swap_is_rejected(
            release_updater,
            lambda path: release_updater.read_root_controlled_bytes(
                path, exact_mode=0o644, maximum_bytes=1024 * 1024
            ),
            release_updater.UpdaterError,
            "require_root_controlled_file",
        )
        self.assert_path_swap_is_rejected(
            runtime_boot,
            lambda path: runtime_boot._stable_root_bytes(
                path, mode=0o644, maximum_bytes=1024 * 1024
            ),
            runtime_boot.BootVerificationError,
            "_require_root_file",
        )


class EarlyBootTemplateContractTest(unittest.TestCase):
    def test_ci_installs_nginx_override_as_a_real_dropin_in_the_unit_graph(self):
        workflow = (PROJECT_ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("nginx-uten-imp-override.conf.example", workflow)
        self.assertIn("nginx.service.d", workflow)
        self.assertIn("systemd-analyze verify", workflow)
        self.assertIn(
            '-p "test_prepare_existing_test_host_internal_runtime.py"',
            workflow,
        )
        self.assertIn("-k SystemdProspectiveContractTest", workflow)
        self.assertNotIn('SYSTEMD_VERIFY="$RUNNER_TEMP', workflow)

    def test_nginx_override_is_accepted_by_systemd_as_a_merged_dropin(self):
        analyzer = Path("/usr/bin/systemd-analyze")
        if not analyzer.is_file():
            self.skipTest("systemd-analyze is unavailable on this platform")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            units = root / "etc/systemd/system"
            dropins = units / "nginx.service.d"
            dropins.mkdir(parents=True)
            executable_paths = (
                root / "usr/bin/python3",
                root / "usr/bin/test",
                root / "usr/bin/true",
                root / "usr/local/libexec/uten-imp-release/recovery_ingress_gate.py",
                root
                / "usr/local/libexec/uten-imp-release/recovery_commit_boot_verifier.py",
                root / "usr/local/libexec/uten-imp/uten-imp-wait-ready",
            )
            for executable in executable_paths:
                executable.parent.mkdir(parents=True, exist_ok=True)
                executable.write_bytes(b"#!/bin/sh\nexit 0\n")
                executable.chmod(0o755)
            base = (
                "[Unit]\nDescription=Fixture Nginx\n"
                "[Service]\nType=simple\nExecStart=/usr/bin/true\n"
            )
            dependency = (
                "[Unit]\nDescription=Fixture dependency\n"
                "[Service]\nType=oneshot\nExecStart=/usr/bin/true\n"
                "RemainAfterExit=yes\n"
            )
            (units / "nginx.service").write_text(base, encoding="utf-8")
            for name in (
                "uten-imp.service",
                "uten-imp-recovery-commit-verifier.service",
            ):
                (units / name).write_text(dependency, encoding="utf-8")
            for name in ("basic.target", "shutdown.target", "sysinit.target"):
                (units / name).write_text(
                    "[Unit]\nDescription=Fixture target\nDefaultDependencies=no\n",
                    encoding="utf-8",
                )
            override = (
                PROJECT_ROOT
                / "deploy/systemd/nginx-uten-imp-override.conf.example"
            ).read_bytes()
            (dropins / "uten-imp.conf").write_bytes(override)
            completed = subprocess.run(
                [
                    str(analyzer),
                    f"--root={root}",
                    "verify",
                    str(units / "nginx.service"),
                    str(units / "uten-imp.service"),
                    str(
                        units
                        / "uten-imp-recovery-commit-verifier.service"
                    ),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    "LANG": "C.UTF-8",
                    "LC_ALL": "C.UTF-8",
                    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
                },
                timeout=30,
                check=False,
            )
            self.assertEqual(
                0,
                completed.returncode,
                completed.stderr.decode("utf-8", errors="replace"),
            )

    def test_both_watchdogs_treat_systemd_finalization_as_fail_closed(self):
        marker = (
            "/var/lib/uten-imp-release/"
            "recovery-ingress-finalizing.json"
        )
        for relative in (
            "deploy/watchdog/uten-imp-watchdog.sh",
            "deploy/watchdog/uten-imp-entry-watchdog.sh",
        ):
            with self.subTest(path=relative):
                source = (PROJECT_ROOT / relative).read_text(encoding="utf-8")
                self.assertEqual(1, source.count(marker), relative)

    def test_second_stage_verifier_runs_after_local_filesystems_before_every_entry(self):
        unit = (
            PROJECT_ROOT
            / "deploy/systemd/uten-imp-recovery-commit-verifier.service.example"
        ).read_text(encoding="utf-8")
        self.assertIn("After=local-fs.target", unit)
        self.assertIn("Wants=local-fs.target", unit)
        self.assertIn(
            "Before=uten-imp.service nginx.service uten-imp-watchdog.timer "
            "uten-imp-entry-watchdog.timer",
            unit,
        )
        self.assertIn(
            "ExecStart=/usr/bin/python3 -I "
            "/usr/local/libexec/uten-imp-release/recovery_commit_boot_verifier.py",
            unit,
        )
        self.assertIn("WantedBy=multi-user.target", unit)

    def test_every_employee_entry_uses_the_lock_bound_recovery_ingress_gate(self):
        paths = (
            "deploy/systemd/uten-imp-internal-test.service.example",
            "deploy/systemd/nginx-uten-imp-override.conf.example",
            "deploy/systemd/uten-imp-watchdog.service.example",
            "deploy/systemd/uten-imp-entry-watchdog.service.example",
        )
        for relative in paths:
            with self.subTest(path=relative):
                source = (PROJECT_ROOT / relative).read_text(encoding="utf-8")
                self.assertTrue(
                    any(
                        line.startswith("Requires=")
                        and "uten-imp-recovery-commit-verifier.service" in line
                        for line in source.splitlines()
                    ),
                    relative,
                )
                self.assertIn(
                    "After=", source
                )
                self.assertIn(
                    "uten-imp-recovery-commit-verifier.service", source
                )
                self.assertIn(
                    "ExecStartPre=", source
                )
                pending_guard = (
                    "/usr/bin/test ! -e "
                    "/var/lib/uten-imp-release/recovery-ingress-pending.json"
                )
                probe_gate = (
                    "/usr/bin/python3 -I "
                    "/usr/local/libexec/uten-imp-release/recovery_ingress_gate.py"
                )
                if relative.endswith("uten-imp-internal-test.service.example"):
                    # Recovery starts the application through its separate,
                    # one-use runtime authorization. Only Nginx/watchdog probes
                    # may cross the still-live post-commit ingress gate.
                    self.assertIn(pending_guard, source)
                    self.assertNotIn(probe_gate, source)
                else:
                    self.assertNotIn(pending_guard, source)
                    self.assertIn(probe_gate, source)

        preparer = (
            PROJECT_ROOT / "deploy/setup/prepare-existing-test-host-internal-runtime.py"
        ).read_text(encoding="utf-8")
        self.assertIn('"recoveryCommitBootUnitSha256"', preparer)
        self.assertIn('"recoveryIngressGateSha256"', preparer)
        self.assertIn(
            '"enable",\n            "uten-imp-recovery-commit-verifier.service"',
            preparer,
        )
        self.assertIn(
            '!= "enabled"', preparer
        )


class InternalTestOnboardingRunbookContractTest(unittest.TestCase):
    def test_runbook_preserves_builder_dispatcher_and_restart_truth(self):
        runbook = (
            PROJECT_ROOT
            / "deploy/setup/EXISTING_TEST_HOST_INTERNAL_TEST_ONBOARDING.zh-CN.md"
        ).read_text(encoding="utf-8")

        # The executable builder is authenticated out of band before Python
        # evaluates it; the same reviewed snapshot and digest are then passed
        # to its mandatory self-binding input.
        self.assertIn("--expected-builder-sha256", runbook)
        self.assertIn("sha256sum", runbook)
        self.assertRegex(runbook, r"(?s)builder.{0,800}stat.{0,800}sha256")

        # The dispatcher is an external systemctl client. Killing it cannot
        # implicitly stop the PID-1-owned worker unit; exact-request reentry
        # adopts that worker's durable terminal instead.
        self.assertIn("PID 1", runbook)
        self.assertIn("\u540c\u53c2\u6570", runbook)
        self.assertRegex(
            runbook,
            r"(?s)dispatcher.{0,500}(\u7ee7\u7eed|\u91c7\u7eb3|adopt)",
        )
        self.assertNotIn(
            "\u7236 dispatcher \u88ab SIGKILL \u65f6\uff0csystemd \u5fc5\u987b\u4ee5",
            runbook,
        )

        # A failed ExecStartPost is one start transaction because the unit has
        # Restart=no, not because one particular exit code suppresses restart.
        self.assertIn("Restart=no", runbook)
        self.assertNotIn("exit 78 \u65e0 restart loop", runbook)


if __name__ == "__main__":
    unittest.main()
