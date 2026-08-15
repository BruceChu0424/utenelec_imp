import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch


MODULE_PATH = Path(__file__).with_name(
    "existing-test-host-internal-db-commissioner.py"
)
SPEC = importlib.util.spec_from_file_location(
    "existing_test_host_internal_db_commissioner", MODULE_PATH
)
assert SPEC is not None and SPEC.loader is not None
commissioner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = commissioner
SPEC.loader.exec_module(commissioner)


TRANSACTION_ID = "internal-test-db-20260812T120000Z-0123456789ab"
BOOT_ID = "00000000-0000-4000-8000-000000000001"
FILESYSTEM_UUID = "11111111-1111-4111-8111-111111111111"


def write_json(path: Path, value: object) -> bytes:
    raw = commissioner.canonical_bytes(value)
    path.write_bytes(raw)
    return raw


def attempt_value(evidence: Path, parent: Path, number: int) -> dict[str, object]:
    return {
        "attempt": number,
        "authorizedAtUtc": f"2026-08-12T12:{number % 60:02d}:00Z",
        "filesystemUuid": FILESYSTEM_UUID,
        "incomingPath": str(
            parent / f".main.incoming-{evidence.name}-{number}"
        ),
        "kind": "uten-imp-internal-test-initdb-attempt",
        "pgDataEmpty": True,
        "schemaVersion": 1,
        "status": "INITDB_RUNNING",
        "transactionId": evidence.name,
    }


class StrictJsonTest(unittest.TestCase):
    def test_duplicate_keys_are_rejected_at_every_depth(self):
        documents = (
            b'{"schemaVersion":1,"schemaVersion":1}',
            b'{"outer":{"value":1,"value":2}}',
        )
        for raw in documents:
            with self.subTest(raw=raw), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "document.json"
                path.write_bytes(raw)
                with patch.object(commissioner, "require_root_file"):
                    with self.assertRaisesRegex(
                        commissioner.CommissioningError, "duplicate key"
                    ):
                        commissioner.strict_json(path, "test document")

    def test_atomic_bytes_retries_partial_writes_before_publish(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "evidence.json"
            real_write = os.write
            writes: list[int] = []

            def short_write(descriptor: int, payload: bytes) -> int:
                chunk = payload[: max(1, len(payload) // 4)]
                written = real_write(descriptor, chunk)
                writes.append(written)
                return written

            with patch.object(commissioner, "require_root_directory"), patch.object(
                commissioner, "fsync_directory"
            ), patch.object(commissioner.os, "chown"), patch.object(
                commissioner.os, "write", side_effect=short_write
            ):
                commissioner.atomic_bytes(target, b"y" * 4096)
            self.assertEqual(b"y" * 4096, target.read_bytes())
            self.assertGreater(len(writes), 1)

    def test_non_finite_numbers_are_rejected(self):
        for token in (b"NaN", b"Infinity", b"-Infinity"):
            with self.subTest(token=token), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "document.json"
                path.write_bytes(b'{"value":' + token + b"}")
                with patch.object(commissioner, "require_root_file"):
                    with self.assertRaisesRegex(
                        commissioner.CommissioningError, "non-finite JSON"
                    ):
                        commissioner.strict_json(path, "test document")


class StorageObservationTest(unittest.TestCase):
    def observation(self) -> dict[str, object]:
        return {
            "authoritySha256": "a" * 64,
            "authorityCommissioningEvidenceSha256": "b" * 64,
            "bootId": BOOT_ID,
            "filesystemUuid": FILESYSTEM_UUID,
            "findmntOutputSha256": "c" * 64,
            "mountedSourceRdev": "253:7",
            "storageBootVerifierOutputSha256": "d" * 64,
            "storageBootVerifierSha256": "e" * 64,
            "storageCommissioningPlanSha256": "f" * 64,
            "storageCommissioningReceiptSha256": "1" * 64,
            "storageValidatorOutputSha256": "2" * 64,
            "storageValidatorSha256": "3" * 64,
            "verifiedAtUtc": "2026-08-12T12:00:00Z",
        }

    def test_observations_are_append_only_and_numerically_sequenced(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / TRANSACTION_ID
            evidence.mkdir(mode=0o700)
            with patch.object(commissioner, "require_root_directory"), patch.object(
                commissioner, "require_root_file"
            ), patch.object(commissioner.os, "chown"), patch.object(
                commissioner, "fsync_directory"
            ):
                first_path, first_sha = commissioner.write_storage_observation(
                    evidence, "before-initdb", self.observation()
                )
                first_raw = first_path.read_bytes()
                second = self.observation()
                second["verifiedAtUtc"] = "2026-08-12T12:01:00Z"
                second_path, second_sha = commissioner.write_storage_observation(
                    evidence, "before-initdb", second
                )

            self.assertTrue(first_path.name.endswith("-1.json"))
            self.assertTrue(second_path.name.endswith("-2.json"))
            self.assertEqual(first_raw, first_path.read_bytes())
            self.assertNotEqual(first_sha, second_sha)
            self.assertEqual(1, json.loads(first_raw)["sequence"])
            self.assertEqual(2, json.loads(second_path.read_bytes())["sequence"])

    def test_unknown_observation_namespace_is_refused_without_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / TRANSACTION_ID
            evidence.mkdir(mode=0o700)
            unknown = evidence / f"storage-before-initdb-{BOOT_ID}-latest.json"
            unknown.write_text("retain me", encoding="ascii")
            with patch.object(commissioner, "require_root_directory"), patch.object(
                commissioner, "require_root_file"
            ):
                with self.assertRaisesRegex(
                    commissioner.CommissioningError, "unexpected entry"
                ):
                    commissioner.write_storage_observation(
                        evidence, "before-initdb", self.observation()
                    )
            self.assertEqual("retain me", unknown.read_text(encoding="ascii"))
            self.assertEqual([unknown], list(evidence.iterdir()))


class InitdbDurabilityTest(unittest.TestCase):
    def invoke(
        self,
        root: Path,
        *,
        attempts: tuple[int, ...] = (),
        unknown_incoming: int | None = None,
    ) -> tuple[Path, Path, list[list[str]], dict[int, bytes]]:
        parent = root / "postgresql" / "16"
        parent.mkdir(parents=True)
        pgdata = parent / "main"
        pgdata.mkdir(mode=0o700)
        evidence = root / TRANSACTION_ID
        evidence.mkdir(mode=0o700)
        original: dict[int, bytes] = {}
        for number in attempts:
            marker = evidence / f"initdb-attempt-{number}.json"
            original[number] = write_json(
                marker, attempt_value(evidence, parent, number)
            )
        if unknown_incoming is not None:
            (parent / f".main.incoming-{evidence.name}-{unknown_incoming}").mkdir(
                mode=0o700
            )

        commands: list[list[str]] = []

        def fake_run(command: list[str], **_kwargs):
            commands.append(command)
            if command and command[0] == "/usr/sbin/runuser" and any(
                Path(argument).name == "initdb" for argument in command
            ):
                incoming = Path(command[command.index("-D") + 1])
                (incoming / "PG_VERSION").write_text("16\n", encoding="ascii")
            return subprocess.CompletedProcess(command, 0, b"", b"")

        account = SimpleNamespace(pw_uid=os.getuid(), pw_gid=os.getgid())
        with patch.object(commissioner, "PG_PARENT", parent), patch.object(
            commissioner, "PGDATA", pgdata
        ), patch.object(commissioner, "require_root_directory"), patch.object(
            commissioner, "require_root_file"
        ), patch.object(commissioner, "fsync_directory"), patch.object(
            commissioner.os, "chown"
        ), patch.object(commissioner.pwd, "getpwnam", return_value=account), patch.object(
            commissioner, "initialized_identity", return_value={"systemIdentifier": "123456789"}
        ), patch.object(commissioner, "run", side_effect=fake_run):
            commissioner.initialize_cluster(
                evidence, {"filesystemUuid": FILESYSTEM_UUID}
            )
        return evidence, parent, commands, original

    def test_resume_after_attempt_marker_before_directory_reuses_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence, _parent, commands, original = self.invoke(
                Path(directory), attempts=(1,)
            )
            marker = evidence / "initdb-attempt-1.json"
            self.assertEqual(original[1], marker.read_bytes())
            self.assertFalse((evidence / "initdb-attempt-2.json").exists())
            self.assertTrue((evidence / "initdb-published.json").is_file())
            initdb_calls = [
                command
                for command in commands
                if any(Path(argument).name == "initdb" for argument in command)
            ]
            self.assertEqual(1, len(initdb_calls))
            self.assertIn(f"-{evidence.name}-1", " ".join(initdb_calls[0]))

    def test_attempt_selection_uses_numeric_not_lexicographic_order(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence, _parent, commands, original = self.invoke(
                Path(directory), attempts=(2, 10)
            )
            self.assertEqual(
                original[10], (evidence / "initdb-attempt-10.json").read_bytes()
            )
            initdb_calls = [
                command
                for command in commands
                if any(Path(argument).name == "initdb" for argument in command)
            ]
            self.assertEqual(1, len(initdb_calls))
            self.assertIn(f"-{evidence.name}-10", " ".join(initdb_calls[0]))

    def test_unbound_incoming_directory_is_refused_before_initdb(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(commissioner.CommissioningError):
                self.invoke(root, unknown_incoming=99)
            unknown = (
                root
                / "postgresql"
                / "16"
                / f".main.incoming-{TRANSACTION_ID}-99"
            )
            self.assertTrue(unknown.is_dir())

    def interrupted_fixture(self, directory: str, *, receipt_written: bool):
        root = Path(directory)
        parent = root / "postgresql" / "16"
        parent.mkdir(parents=True)
        pgdata = parent / "main"
        pgdata.mkdir(mode=0o700)
        evidence = root / TRANSACTION_ID
        evidence.mkdir(mode=0o700)
        attempt = evidence / "initdb-attempt-1.json"
        write_json(attempt, attempt_value(evidence, parent, 1))
        directory_receipt = evidence / "initdb-directory-created-1.json"
        write_json(
            directory_receipt,
            {
                "attempt": 1,
                "createdAtUtc": "2026-08-12T12:01:00Z",
                "incomingPath": str(parent / f".main.incoming-{evidence.name}-1"),
                "kind": "uten-imp-internal-test-initdb-directory",
                "schemaVersion": 1,
                "status": "EMPTY_DIRECTORY_CREATED",
                "transactionId": evidence.name,
            },
        )
        abandoned = parent / f".main.incomplete-{evidence.name}-1"
        abandoned.mkdir(mode=0o700)
        authority = evidence / "initdb-abandon-authorized-1.json"
        authority_value = {
            "abandonedPath": str(abandoned),
            "attempt": 1,
            "attemptSha256": commissioner.sha256_file(attempt),
            "authorizedAtUtc": "2026-08-12T12:02:00Z",
            "directoryReceiptSha256": commissioner.sha256_file(directory_receipt),
            "filesystemUuid": FILESYSTEM_UUID,
            "incomingPath": str(parent / f".main.incoming-{evidence.name}-1"),
            "kind": "uten-imp-internal-test-initdb-abandonment-authority",
            "schemaVersion": 1,
            "status": "INCOMPLETE_ATTEMPT_RETENTION_AUTHORIZED",
            "transactionId": evidence.name,
        }
        write_json(authority, authority_value)
        if receipt_written:
            write_json(
                evidence / "initdb-abandoned-1.json",
                {
                    "abandonedPath": str(abandoned),
                    "attempt": 1,
                    "abandonmentAuthoritySha256": commissioner.sha256_file(authority),
                    "filesystemUuid": FILESYSTEM_UUID,
                    "kind": "uten-imp-internal-test-incomplete-initdb",
                    "retainedAtUtc": authority_value["authorizedAtUtc"],
                    "schemaVersion": 1,
                    "status": "INCOMPLETE_ATTEMPT_RETAINED",
                    "transactionId": evidence.name,
                },
            )
        return root, parent, pgdata, evidence, abandoned

    def invoke_interrupted(self, root, parent, pgdata, evidence):
        commands: list[list[str]] = []

        def fake_run(command: list[str], **_kwargs):
            commands.append(command)
            if command and command[0] == "/usr/sbin/runuser" and any(
                Path(argument).name == "initdb" for argument in command
            ):
                incoming = Path(command[command.index("-D") + 1])
                (incoming / "PG_VERSION").write_text("16\n", encoding="ascii")
            return subprocess.CompletedProcess(command, 0, b"", b"")

        account = SimpleNamespace(pw_uid=os.getuid(), pw_gid=os.getgid())
        with patch.object(commissioner, "PG_PARENT", parent), patch.object(
            commissioner, "PGDATA", pgdata
        ), patch.object(commissioner, "require_root_directory"), patch.object(
            commissioner, "require_root_file"
        ), patch.object(commissioner, "fsync_directory"), patch.object(
            commissioner.os, "chown"
        ), patch.object(
            commissioner.pwd, "getpwnam", return_value=account
        ), patch.object(
            commissioner,
            "initialized_identity",
            side_effect=lambda path: {"systemIdentifier": "123456789"}
            if (path / "PG_VERSION").is_file()
            else (_ for _ in ()).throw(commissioner.CommissioningError("partial")),
        ), patch.object(commissioner, "run", side_effect=fake_run):
            commissioner.initialize_cluster(
                evidence, {"filesystemUuid": FILESYSTEM_UUID}
            )
        return commands

    def test_resume_after_incomplete_rename_before_receipt_adopts_then_uses_attempt_two(self):
        with tempfile.TemporaryDirectory() as directory:
            root, parent, pgdata, evidence, abandoned = self.interrupted_fixture(
                directory, receipt_written=False
            )
            commands = self.invoke_interrupted(root, parent, pgdata, evidence)
            self.assertTrue(abandoned.is_dir())
            self.assertTrue((evidence / "initdb-abandoned-1.json").is_file())
            self.assertTrue((evidence / "initdb-attempt-2.json").is_file())
            self.assertTrue((evidence / "initdb-published.json").is_file())
            self.assertEqual(
                1,
                sum(
                    any(Path(argument).name == "initdb" for argument in command)
                    for command in commands
                ),
            )

    def test_resume_after_abandoned_receipt_before_attempt_two_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            root, parent, pgdata, evidence, abandoned = self.interrupted_fixture(
                directory, receipt_written=True
            )
            receipt = evidence / "initdb-abandoned-1.json"
            before = receipt.read_bytes()
            self.invoke_interrupted(root, parent, pgdata, evidence)
            self.assertEqual(before, receipt.read_bytes())
            self.assertTrue(abandoned.is_dir())
            self.assertTrue((evidence / "initdb-attempt-2.json").is_file())
            self.assertTrue((evidence / "initdb-published.json").is_file())


class CredentialBoundaryTest(unittest.TestCase):
    def test_runtime_secret_mismatch_is_rejected_before_database_mutation(self):
        with patch.object(
            commissioner,
            "secret_value",
            side_effect=("A" * 32, "M" * 32),
        ) as read_secret, patch.object(
            commissioner, "environment_value", return_value="B" * 32
        ), patch.object(commissioner, "run") as run:
            with self.assertRaisesRegex(
                commissioner.CommissioningError,
                "application database secret differs",
            ):
                commissioner.verify_runtime_secret_binding()
        self.assertEqual(1, read_secret.call_count)
        run.assert_not_called()

    def test_loopback_credentials_are_environment_only_and_both_roles_are_proved(self):
        app_password = "A" * 32
        migrator_password = "M" * 32
        calls: list[tuple[list[str], dict[str, object]]] = []

        def fake_run(command: list[str], **kwargs):
            calls.append((command, kwargs))
            return subprocess.CompletedProcess(command, 0, b"1\n", b"")

        with patch.object(
            commissioner,
            "verify_runtime_secret_binding",
            return_value=(app_password, migrator_password),
        ), patch.object(commissioner, "run", side_effect=fake_run):
            commissioner.verify_database_credentials()

        self.assertEqual(2, len(calls))
        self.assertEqual(["uten", "uten_migrator"], [call[0][call[0].index("-U") + 1] for call in calls])
        for command, kwargs in calls:
            serialized = " ".join(command)
            self.assertNotIn(app_password, serialized)
            self.assertNotIn(migrator_password, serialized)
            self.assertIsNone(kwargs.get("input_bytes"))
            self.assertIn(
                kwargs["environment"]["PGPASSWORD"],
                {app_password, migrator_password},
            )

    def test_psql_metacharacters_are_rejected_before_command_or_receipt(self):
        values = (
            "A" * 20 + "'",
            "A" * 20 + "\\",
            "A" * 20 + "\nBAD",
            "A" * 20 + ":'psql'",
        )
        for index, secret in enumerate(values):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                evidence = root / TRANSACTION_ID
                evidence.mkdir()
                app = root / "app.password"
                migrator = root / "migrator.password"
                app.write_text(secret, encoding="ascii")
                migrator.write_text("B" * 24, encoding="ascii")
                command = Mock()
                receipt = Mock()
                stdout = io.StringIO()
                stderr = io.StringIO()
                with patch.object(commissioner, "APP_PASSWORD", app), patch.object(
                    commissioner, "MIGRATOR_PASSWORD", migrator
                ), patch.object(commissioner, "require_root_file"), patch.object(
                    commissioner.grp,
                    "getgrnam",
                    return_value=SimpleNamespace(gr_gid=os.getgid()),
                ), patch.object(commissioner, "run", command), patch.object(
                    commissioner, "atomic_json", receipt
                ), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    with self.assertRaises(commissioner.CommissioningError) as raised:
                        commissioner.configure_roles(evidence)
                command.assert_not_called()
                receipt.assert_not_called()
                combined = stdout.getvalue() + stderr.getvalue() + str(raised.exception)
                self.assertNotIn(secret, combined)

    def test_accepted_migrator_password_is_environment_only(self):
        password = "Q" * 32
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / TRANSACTION_ID
            extracted = root / "payload"
            jar = extracted / "server" / "uten-imp-migrator.jar"
            evidence.mkdir()
            jar.parent.mkdir(parents=True)
            jar.write_bytes(b"signed migrator")
            execution = root / "execution"
            calls: list[tuple[list[str], dict[str, object]]] = []
            receipts: list[object] = []

            def fake_mkdtemp(**_kwargs):
                execution.mkdir()
                return str(execution)

            def fake_run(command: list[str], **kwargs):
                calls.append((command, kwargs))
                output = (
                    b"UTEN_MIGRATION_VALIDATE_OK\n"
                    b"UTEN_MIGRATION_OK migrations_executed=1\n"
                )
                return subprocess.CompletedProcess(command, 0, output, b"")

            manifest = {"migratorJarSha256": commissioner.sha256_file(jar)}
            with patch.object(commissioner, "require_root_file"), patch.object(
                commissioner, "require_root_directory"
            ), patch.object(
                commissioner.pwd,
                "getpwnam",
                return_value=SimpleNamespace(pw_gid=os.getgid()),
            ), patch.object(
                commissioner, "WORKER_RUNTIME", root
            ), patch.object(commissioner.tempfile, "mkdtemp", side_effect=fake_mkdtemp), patch.object(
                commissioner.os, "chown"
            ), patch.object(commissioner, "secret_value", return_value=password), patch.object(
                commissioner, "run", side_effect=fake_run
            ), patch.object(
                commissioner,
                "atomic_json",
                side_effect=lambda _path, value, **_kwargs: receipts.append(value),
            ):
                commissioner.run_migrator(evidence, extracted, manifest)

            self.assertEqual(1, len(calls))
            command, kwargs = calls[0]
            self.assertNotIn(password, " ".join(command))
            self.assertEqual(
                password, kwargs["environment"]["UTEN_MIGRATOR_DB_PASSWORD"]
            )
            self.assertNotIn(password, json.dumps(receipts, sort_keys=True))
            self.assertNotIn(password.encode("ascii"), kwargs.get("input_bytes") or b"")


class HostPreparationTerminalTest(unittest.TestCase):
    def fixture(self, directory: str):
        evidence = Path(directory) / "host-preparation"
        transaction = evidence / "prepare-internal-runtime-0123456789abcdef"
        snapshot = transaction / "source-snapshot"
        snapshot.mkdir(parents=True, mode=0o700)
        sources = {
            "databaseCommissionerSha256": b"commissioner\n",
            "manifestBuilderSha256": b"manifest builder\n",
            "nginxTemplateSha256": b"nginx\n",
        }
        source_sha = {}
        for key, raw in sources.items():
            path = snapshot / key
            path.write_bytes(raw)
            source_sha[key] = commissioner.sha256_file(path)
        reviewed = {
            "approvalReference": "CHG-2026-0812-INTERNAL",
            "builderSha256": source_sha["manifestBuilderSha256"],
            "createdAtUtc": "2026-08-12T11:00:00Z",
            "expiresAtUtc": "2026-08-13T11:00:00Z",
            "hostParameters": {},
            "kind": "uten-imp-internal-test-reviewed-host-sources",
            "preparerSha256": "e" * 64,
            "schemaVersion": 1,
            "sourceSha256": source_sha,
            "targetPreimageSha256": {},
        }
        reviewed_path = transaction / "reviewed-source-manifest.json"
        write_json(reviewed_path, reviewed)
        reviewed_sha = commissioner.sha256_file(reviewed_path)
        plan = {
            "approvalReference": reviewed["approvalReference"],
            "entryEnabled": False,
            "kind": "uten-imp-internal-test-host-preparation-plan",
            "reviewedSourceManifestPath": str(reviewed_path),
            "reviewedSourceManifestSha256": reviewed_sha,
            "schemaVersion": 1,
            "sourceSha256": source_sha,
            "sourceSnapshotPath": str(snapshot),
            "status": "APPROVED_ENTRY_CLOSED",
            "transactionId": transaction.name,
        }
        plan_path = transaction / "plan.json"
        write_json(plan_path, plan)
        inventory_sha = commissioner.hashlib.sha256(
            commissioner.canonical_bytes(source_sha)
        ).hexdigest()
        mutation = {
            "authorizedAtUtc": "2026-08-12T12:00:00Z",
            "kind": "uten-imp-internal-test-host-mutation-authority",
            "planPath": str(plan_path),
            "planSha256": commissioner.sha256_file(plan_path),
            "reviewedSourceManifestSha256": reviewed_sha,
            "schemaVersion": 1,
            "snapshotInventorySha256": inventory_sha,
            "status": "MUTATION_AUTHORIZED_ENTRY_CLOSED",
            "transactionId": transaction.name,
        }
        mutation_path = transaction / "mutation-authorized.committed.json"
        write_json(mutation_path, mutation)
        contract_sha = "c" * 64
        terminal = {
            "contractSha256": contract_sha,
            "entryEnabled": False,
            "kind": "uten-imp-internal-test-host-preparation-receipt",
            "mutationAuthorityPath": str(mutation_path),
            "mutationAuthoritySha256": commissioner.sha256_file(mutation_path),
            "nginxEnabledLink": "/etc/nginx/sites-enabled/uten-imp-internal-test.conf",
            "nginxEnabledTargetSha256": "d" * 64,
            "planSha256": commissioner.sha256_file(plan_path),
            "productionAuthority": False,
            "schemaVersion": 1,
            "status": "COMMITTED_ENTRY_CLOSED",
            "transactionId": transaction.name,
        }
        complete = transaction / "complete.json"
        active = evidence / "active.json"
        write_json(complete, terminal)
        write_json(active, terminal)
        mutation_active = evidence / "mutation-active.json"
        return evidence, active, mutation_active, mutation_path, terminal, contract_sha

    def invoke(self, evidence: Path, active: Path, mutation_active: Path, contract_sha: str):
        with patch.object(
            commissioner, "HOST_PREPARATION_EVIDENCE", evidence
        ), patch.object(
            commissioner, "HOST_PREPARATION_ACTIVE", active
        ), patch.object(
            commissioner, "HOST_PREPARATION_MUTATION_ACTIVE", mutation_active
        ), patch.object(commissioner, "require_root_file"), patch.object(
            commissioner, "require_root_directory"
        ):
            return commissioner.validate_host_preparation_terminal(contract_sha)

    def test_committed_renamed_authority_is_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence, active, mutation_active, _mutation, terminal, contract_sha = self.fixture(
                directory
            )
            result = self.invoke(evidence, active, mutation_active, contract_sha)
        self.assertEqual(terminal, result)

    def test_live_mutation_path_is_refused_even_when_terminal_claims_success(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence, active, mutation_active, mutation, _terminal, contract_sha = self.fixture(
                directory
            )
            mutation_active.write_bytes(mutation.read_bytes())
            mutation.unlink()
            with self.assertRaisesRegex(
                commissioner.CommissioningError, "still active"
            ):
                self.invoke(evidence, active, mutation_active, contract_sha)
            self.assertTrue(mutation_active.is_file())


class DatabaseTerminalEvidenceTest(unittest.TestCase):
    def fixture(self, directory: str):
        base = Path(directory) / "database-commissioning"
        evidence = base / TRANSACTION_ID
        evidence.mkdir(parents=True, mode=0o700)
        plan_path = evidence / "transaction-manifest.json"
        write_json(
            plan_path,
            {
                "approvalReference": "CHG-2026-0812-INTERNAL",
                "transactionId": evidence.name,
            },
        )
        plan_sha = commissioner.sha256_file(plan_path)
        pointer = {
            "evidencePath": str(evidence),
            "planSha256": plan_sha,
            "schemaVersion": 1,
            "transactionId": evidence.name,
        }
        write_json(evidence / "active-pointer.committed.json", pointer)
        onboarding_sha = "a" * 64
        complete = {
            "completedAtUtc": "2026-08-12T12:10:00Z",
            "entryEnabled": False,
            "kind": "uten-imp-internal-test-database-commissioning-receipt",
            "onboardingReceiptSha256": onboarding_sha,
            "productionAuthority": False,
            "schemaVersion": 1,
            "status": "COMMITTED_AWAITING_FIRST_ACTIVATION",
            "transactionId": evidence.name,
        }
        write_json(evidence / "complete.json", complete)
        return base, evidence, plan_sha, onboarding_sha, pointer, complete

    def test_sigkill_after_pointer_rename_adopts_exact_terminal_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            base, evidence, plan_sha, onboarding_sha, pointer, complete = self.fixture(
                directory
            )
            with patch.object(commissioner, "EVIDENCE_BASE", base), patch.object(
                commissioner, "require_root_file"
            ):
                self.assertEqual(
                    pointer,
                    commissioner.validate_committed_pointer(evidence, plan_sha),
                )
                self.assertEqual(
                    complete,
                    commissioner.validate_complete_receipt(
                        evidence, onboarding_sha
                    ),
                )

    def test_committed_pointer_rejects_schema_and_plan_tampering(self):
        for mutation in ("extra-key", "wrong-plan"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                base, evidence, plan_sha, _onboarding_sha, pointer, _complete = self.fixture(
                    directory
                )
                if mutation == "extra-key":
                    pointer["unexpected"] = True
                else:
                    pointer["planSha256"] = "b" * 64
                write_json(evidence / "active-pointer.committed.json", pointer)
                with patch.object(commissioner, "EVIDENCE_BASE", base), patch.object(
                    commissioner, "require_root_file"
                ), self.assertRaises(commissioner.CommissioningError):
                    commissioner.validate_committed_pointer(evidence, plan_sha)

    def test_complete_receipt_rejects_control_field_and_extra_key_tampering(self):
        for mutation in ("entry-enabled", "production-authority", "extra-key"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                base, evidence, _plan_sha, onboarding_sha, _pointer, complete = self.fixture(
                    directory
                )
                if mutation == "entry-enabled":
                    complete["entryEnabled"] = True
                elif mutation == "production-authority":
                    complete["productionAuthority"] = True
                else:
                    complete["unexpected"] = True
                write_json(evidence / "complete.json", complete)
                with patch.object(commissioner, "EVIDENCE_BASE", base), patch.object(
                    commissioner, "require_root_file"
                ), self.assertRaises(commissioner.CommissioningError):
                    commissioner.validate_complete_receipt(evidence, onboarding_sha)


class PostgresBootEvidenceTest(unittest.TestCase):
    def test_preparing_and_committed_receipts_are_exact_and_transaction_bound(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / TRANSACTION_ID
            evidence.mkdir()
            preparing = {
                "entryEnabled": False,
                "kind": "uten-imp-internal-test-postgres-boot-transition",
                "recordedAtUtc": "2026-08-12T12:00:00Z",
                "schemaVersion": 1,
                "status": "POSTGRES_BOOT_PREPARING",
                "transactionId": TRANSACTION_ID,
            }
            committed = {
                "committedAtUtc": "2026-08-12T12:01:00Z",
                "entryEnabled": False,
                "kind": "uten-imp-internal-test-postgres-boot-transition",
                "schemaVersion": 1,
                "status": "POSTGRES_BOOT_COMMITTED_ENTRY_CLOSED",
                "transactionId": TRANSACTION_ID,
                "units": [commissioner.POSTGRES_META_UNIT, commissioner.POSTGRES_UNIT],
            }
            write_json(evidence / "postgres-boot-preparing.json", preparing)
            write_json(evidence / "postgres-boot-committed.json", committed)
            with patch.object(commissioner, "require_root_file"):
                self.assertEqual(
                    preparing, commissioner.validate_postgres_boot_preparing(evidence)
                )
                self.assertEqual(
                    committed, commissioner.validate_postgres_boot_commit(evidence)
                )

            for name, value in (
                ("preparing-extra", {**preparing, "unexpected": True}),
                ("preparing-time", {**preparing, "recordedAtUtc": "not-a-time"}),
                ("committed-units", {**committed, "units": [commissioner.POSTGRES_UNIT]}),
                ("committed-entry", {**committed, "entryEnabled": True}),
            ):
                with self.subTest(name=name), patch.object(
                    commissioner, "require_root_file"
                ), self.assertRaises(commissioner.CommissioningError):
                    if name.startswith("preparing"):
                        write_json(evidence / "postgres-boot-preparing.json", value)
                        commissioner.validate_postgres_boot_preparing(evidence)
                        write_json(evidence / "postgres-boot-preparing.json", preparing)
                    else:
                        write_json(evidence / "postgres-boot-committed.json", value)
                        commissioner.validate_postgres_boot_commit(evidence)
                        write_json(evidence / "postgres-boot-committed.json", committed)


class ExistingOnboardingTest(unittest.TestCase):
    class Lock:
        def __init__(self, *_args, **_kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

    def test_same_version_receipt_with_different_authority_is_not_success(self):
        version = "v2026.08.12-1"
        approval = "CHG-2026-0812-INTERNAL"
        worker_request = commissioner.worker_request_value(
            version,
            approval,
            boot_id=BOOT_ID,
            unit_sha256="d" * 64,
            runtime_contract_sha256="c" * 64,
        )
        with tempfile.TemporaryDirectory() as directory:
            onboarding_path = Path(directory) / "onboarding.json"
            onboarding_path.write_text("{}", encoding="ascii")
            receipt = {
                "approvalReference": "CHG-2026-0812-DIFFERENT",
                "manifest": {"version": version},
                "runtimeContractSha256": "c" * 64,
                "storageCommissioningReceiptSha256": "s" * 64,
            }
            validate_receipt = Mock()
            updater = SimpleNamespace(
                StateLock=self.Lock,
                DEFAULT_LOCK_FILE=Path("/fixed/lock"),
                DatabaseMaintenanceLock=self.Lock,
                assert_pre_database_runtime_contract=lambda: None,
                validate_internal_test_onboarding_receipt=validate_receipt,
            )
            with patch.object(commissioner.os, "geteuid", return_value=0), patch.object(
                commissioner, "ONBOARDING_RECEIPT", onboarding_path
            ), patch.object(
                commissioner,
                "bootstrap_runtime_contract",
                return_value=({}, "b" * 64),
            ), patch.object(commissioner, "load_modules", return_value=(updater, object())), patch.object(
                commissioner, "require_entry_closed"
            ), patch.object(
                commissioner,
                "runtime_contract",
                return_value=({}, "c" * 64),
            ), patch.object(
                commissioner, "validate_worker_request_live"
            ), patch.object(
                commissioner,
                "verify_runtime_secret_binding",
                return_value=("A" * 32, "M" * 32),
            ), patch.object(
                commissioner,
                "storage_receipt",
                return_value=(Path("/fixed/storage.json"), {}, "s" * 64),
            ), patch.object(
                commissioner, "validate_storage_terminal_contract"
            ), patch.object(
                commissioner,
                "verify_live_storage",
                return_value={"bootId": BOOT_ID},
            ), patch.object(commissioner, "strict_json", return_value=receipt):
                with self.assertRaisesRegex(
                    commissioner.CommissioningError,
                    "existing onboarding receipt differs",
                ):
                    commissioner.apply(
                        version,
                        approval,
                        worker_request_sha256="e" * 64,
                        worker_request=worker_request,
                    )
            validate_receipt.assert_called_once_with(
                receipt, require_worker_terminal=False
            )


if __name__ == "__main__":
    unittest.main()
