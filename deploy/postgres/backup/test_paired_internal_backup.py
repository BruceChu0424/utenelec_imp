"""Linux root + disposable local PostgreSQL tests; never target the company DB.

UTEN_RUN_PAIRED_BACKUP_TESTS=1 python3 -m unittest test_paired_internal_backup -v
Run in the isolated test container documented in the evidence, with PostgreSQL
already listening on its private Unix socket. Tests create/drop only their own
randomly named databases and temporary directories.
"""
import dataclasses
import gzip
import hashlib
import json
import os
from pathlib import Path
import pwd
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch

import paired_internal_backup as paired


@unittest.skipUnless(hasattr(os, "O_NOFOLLOW"), "POSIX atomic state files")
class PairedAttemptMetadataTest(unittest.TestCase):
    def test_corrupt_success_pointer_is_never_reported_as_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for value in (123, None, "not-a-time", "2999-01-01T00:00:00Z"):
                (root / "latest-success.json").write_text(json.dumps({"completed_at": value}))
                self.assertIsNone(paired.last_success_time(root))

    def test_failed_attempt_atomically_preserves_previous_success_without_private_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            completed = "2020-01-01T00:00:00+00:00"
            pointer = json.dumps({"set_id": "private-set-name", "completed_at": completed}).encode()
            (root / "latest-success.json").write_bytes(pointer)
            paired.record_attempt(root, "FAILED", paired.now(), paired.now())
            state = json.loads((root / "last-attempt.json").read_text())
            self.assertEqual("FAILED", state["status"])
            self.assertEqual(completed, state["lastSuccessAt"])
            self.assertEqual(pointer, (root / "latest-success.json").read_bytes())
            self.assertNotIn("private-set-name", json.dumps(state))
            self.assertEqual([], list(root.glob(".attempt-*")))
            self.assertEqual(0o600, stat_mode(root / "last-attempt.json"))


class PairedDeleteChainContractTest(unittest.TestCase):
    def test_application_deletion_still_requires_committed_metadata_intent(self):
        root = Path(__file__).resolve().parents[3]
        feature = root / "server/src/main/java/com/uten/imp/features/attachment"
        service = (feature / "AttachmentService.java").read_text(encoding="utf-8")
        start = service.index("public void delete(UUID id)")
        self.assertIn("@Transactional", service[start - 80:start])
        method = service[start:service.index("public void storeRaw", start)]
        self.assertLess(method.index("AttachmentLifecycleState.DELETE_PENDING"), method.index("objectOutbox.enqueueFinal"))
        self.assertLess(method.index("repository.saveAndFlush(attachment)"), method.index("objectOutbox.enqueueFinal"))
        processor = (feature / "AttachmentObjectOutboxProcessor.java").read_text(encoding="utf-8")
        self.assertLess(processor.index("OutboxItem item = claimNext()"), processor.index("storage.delete(item.storageKey()"))
        approval = (feature / "AttachmentReconciliationApprovalTransaction.java").read_text(encoding="utf-8")
        self.assertLess(approval.index("pg_advisory_xact_lock"), approval.index("AttachmentReconciliationService.isReferenced"))
        self.assertLess(approval.index("AttachmentReconciliationService.isReferenced"), approval.index("outbox.enqueueFinal"))
        reference = (feature / "AttachmentReconciliationService.java").read_text(encoding="utf-8")
        self.assertIn("lifecycle_state <> 'DELETED'", reference)


@unittest.skipUnless(os.environ.get("UTEN_RUN_PAIRED_BACKUP_TESTS") == "1", "isolated Linux PG opt-in")
class PairedInternalBackupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="uten-paired-test-")
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        (self.source / "final").mkdir(parents=True)
        self.target = self.root / "paired"
        self.target.mkdir(mode=0o700)
        self.database = "paired_test_" + uuid.uuid4().hex[:12]
        self.config = paired.Config(database=self.database, media_root=str(self.source),
                                    backup_root=str(self.target), pg_dump=shutil.which("pg_dump"),
                                    min_free_bytes=1, min_free_percent=1,
                                    bytes_per_second=100 * 1024**2, max_seconds=120)
        self.created_databases = []
        self.create_database(self.database)
        with self.connection() as connection, connection.cursor() as cursor:
            cursor.execute("""
                CREATE TABLE attachments (
                  id uuid PRIMARY KEY, owner_type text NOT NULL, owner_id uuid NOT NULL,
                  storage_key text UNIQUE NOT NULL, storage_version text NOT NULL,
                  sha256 text NOT NULL, size_bytes bigint NOT NULL, stored_size_bytes bigint,
                  storage_encoding text, storage_provider text, lifecycle_state text NOT NULL);
                CREATE TABLE attachment_object_outbox (
                  id uuid PRIMARY KEY, attachment_id uuid, operation text NOT NULL,
                  storage_key text NOT NULL, storage_version text, storage_provider text,
                  status text NOT NULL);
                CREATE TABLE business_facts (id integer PRIMARY KEY, exact_amount numeric(28,8));
                INSERT INTO business_facts VALUES (1,123.12345678);
            """)

    def tearDown(self):
        for database in self.created_databases:
            connection = paired.connect_peer(dataclasses.replace(self.config, database="postgres"))
            connection.autocommit = True
            with connection.cursor() as cursor:
                cursor.execute('DROP DATABASE "' + database + '" WITH (FORCE)')
            connection.close()
        self.temp.cleanup()

    def connection(self):
        return paired.connect_peer(self.config)

    def create_database(self, name):
        connection = paired.connect_peer(dataclasses.replace(self.config, database="postgres"))
        connection.autocommit = True
        with connection.cursor() as cursor:
            cursor.execute('CREATE DATABASE "' + name + '"')
        connection.close()
        self.created_databases.append(name)

    def add_object(self, *, compressed=False, provider="internal"):
        data = (b"actual-bank-document\n" * 15000) if compressed else b"\x89PNG\r\noriginal bytes\x00\xff"
        digest = hashlib.sha256(data).hexdigest()
        key = "i1_FINANCE_RECEIPT_202609_" + uuid.uuid4().hex + (".txt" if compressed else ".png")
        payload = gzip.compress(data, compresslevel=1, mtime=0) if compressed else data
        encoded = struct.pack(">8sBqq32s", paired.MAGIC, int(compressed), len(data), len(payload), bytes.fromhex(digest)) + payload
        path = self.source / "final" / paired.relative_key(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(encoded)
        row_id = str(uuid.uuid4())
        row = (row_id, "FINANCE_RECEIPT", str(uuid.uuid4()), key, "internal-v1:" + digest,
               digest, len(data), len(encoded), "GZIP" if compressed else "IDENTITY", provider)
        with self.connection() as connection, connection.cursor() as cursor:
            cursor.execute("INSERT INTO attachments VALUES (" + ",".join(["%s"] * 10) + ", 'CLEAN')", row)
        return row_id, key, path, data

    def latest(self):
        return (self.target / "latest-success.json").read_bytes()

    def test_full_pair_restores_exact_database_and_both_original_codecs(self):
        objects = [self.add_object(), self.add_object(compressed=True)]
        published = paired.backup(self.config)
        summary = paired.verify_set(published)
        self.assertEqual(2, summary["clean_objects"])
        attempt = json.loads((self.target / "last-attempt.json").read_text())
        self.assertEqual("SUCCESS", attempt["status"])
        self.assertEqual(summary["completed_at"], attempt["lastSuccessAt"])
        self.assertEqual(0o600, stat_mode(self.target / "last-attempt.json"))
        self.assertEqual({"format", "status", "startedAt", "completedAt", "lastSuccessAt"}, set(attempt))
        restored = self.database + "_restore"
        self.create_database(restored)
        account = pwd.getpwnam("postgres")
        # Private archive is opened by root and passed over stdin, preserving 0700 backup access.
        with (published / "database.dump").open("rb") as source:
            subprocess.run([shutil.which("pg_restore"), "--exit-on-error", "--dbname=" + restored,
                            "--host=" + self.config.socket_directory, "--username=postgres"],
                           stdin=source, check=True, user=account.pw_uid, group=account.pw_gid, extra_groups=[])
        connection = paired.connect_peer(dataclasses.replace(self.config, database=restored))
        with connection, connection.cursor() as cursor:
            cursor.execute("SELECT id::text, storage_key, sha256 FROM attachments ORDER BY id")
            rows = cursor.fetchall()
            cursor.execute("SELECT exact_amount::text FROM business_facts")
            self.assertEqual("123.12345678", cursor.fetchone()[0])
        self.assertEqual({value[0] for value in objects}, {row[0] for row in rows})
        cold_root = self.root / "cold-restored"
        shutil.copytree(published / "media", cold_root)
        for _, key, original_path, data in objects:
            original_path.unlink()
            stored = (cold_root / "final" / paired.relative_key(key)).read_bytes()
            decoded = gzip.decompress(stored[57:]) if stored[8] == 1 else stored[57:]
            self.assertEqual(data, decoded)
        self.assertEqual(0o700, stat_mode(published))
        self.assertEqual(0o600, stat_mode(published / "objects.jsonl"))

    def test_share_lock_blocks_delete_intent_and_physical_worker_but_not_new_upload(self):
        first = self.add_object(compressed=True)
        entered, release, deleted = threading.Event(), threading.Event(), threading.Event()
        failures = []
        results = []
        # Open peer sessions before threads: seteuid is process-wide. Production
        # backup and application workers are separate processes, never threads.
        delete_connection = self.connection()
        worker_connection = self.connection()
        original_copy = paired.copy_object
        def slow_copy(*args):
            entered.set()
            if not release.wait(15):
                raise TimeoutError("test barrier")
            return original_copy(*args)
        def run_backup():
            try:
                results.append(paired.backup(self.config))
            except BaseException as error:
                failures.append(error)
        def delete_like_service_and_worker():
            try:
                # Same order as AttachmentService.delete: UPDATE+outbox in one tx.
                with delete_connection as connection, connection.cursor() as cursor:
                    cursor.execute("UPDATE attachments SET lifecycle_state='DELETE_PENDING' WHERE id=%s", (first[0],))
                    cursor.execute("INSERT INTO attachment_object_outbox SELECT %s,id,'DELETE_FINAL',storage_key,storage_version,storage_provider,'PENDING' FROM attachments WHERE id=%s",
                                   (str(uuid.uuid4()), first[0]))
                # Actual processor can see only committed intent, then deletes bytes.
                with worker_connection as connection, connection.cursor() as cursor:
                    cursor.execute("SELECT storage_key FROM attachment_object_outbox WHERE status='PENDING'")
                    for row in cursor.fetchall():
                        (self.source / "final" / paired.relative_key(row[0])).unlink()
                deleted.set()
            except BaseException as error:
                failures.append(error)
        with patch.object(paired, "copy_object", side_effect=slow_copy):
            worker = threading.Thread(target=run_backup)
            worker.start()
            self.assertTrue(entered.wait(10))
            deleter = threading.Thread(target=delete_like_service_and_worker)
            deleter.start()
            second = self.add_object()
            time.sleep(0.3)
            self.assertFalse(deleted.is_set())
            self.assertTrue(first[2].exists())
            with self.connection() as connection, connection.cursor() as cursor:
                cursor.execute("SELECT COUNT(*) FROM attachment_object_outbox")
                self.assertEqual(0, cursor.fetchone()[0])
                cursor.execute("SELECT COUNT(*) FROM attachments")
                self.assertEqual(2, cursor.fetchone()[0])
            release.set()
            worker.join(20); deleter.join(20)
        self.assertFalse(worker.is_alive() or deleter.is_alive())
        self.assertEqual([], failures)
        self.assertTrue(deleted.is_set())
        self.assertTrue(second[2].exists())
        self.assertEqual(1, paired.verify_set(results[0])["clean_objects"])
        delete_connection.close()
        worker_connection.close()

    def test_tamper_missing_provider_and_queue_faults_preserve_previous_success(self):
        first = self.add_object()
        old = paired.backup(self.config)
        pointer = self.latest()
        original = first[2].read_bytes()
        for fault in ("tamper", "missing", "provider", "outbox"):
            with self.subTest(fault=fault):
                if fault == "tamper":
                    first[2].write_bytes(original[:-1] + b"!")
                elif fault == "missing":
                    first[2].unlink()
                else:
                    with self.connection() as connection, connection.cursor() as cursor:
                        if fault == "provider":
                            cursor.execute("UPDATE attachments SET storage_provider='legacy_unknown'")
                        else:
                            cursor.execute("INSERT INTO attachment_object_outbox SELECT %s,id,'DELETE_FINAL',storage_key,storage_version,storage_provider,'PROCESSING' FROM attachments", (str(uuid.uuid4()),))
                with self.assertRaises(Exception):
                    paired.backup(self.config)
                self.assertEqual(pointer, self.latest())
                self.assertTrue(old.exists())
                attempt = json.loads((self.target / "last-attempt.json").read_text())
                self.assertEqual("FAILED", attempt["status"])
                self.assertEqual(json.loads(pointer)["completed_at"], attempt["lastSuccessAt"])
                first[2].write_bytes(original)
                with self.connection() as connection, connection.cursor() as cursor:
                    cursor.execute("UPDATE attachments SET storage_provider='internal'")
                    cursor.execute("DELETE FROM attachment_object_outbox")

    def test_concurrent_update_after_snapshot_causes_40001_and_no_partial_success(self):
        self.add_object()
        old = paired.backup(self.config)
        pointer = self.latest()
        original_check = paired.assert_consistent
        calls = 0
        def concurrent_change(cursor):
            nonlocal calls
            original_check(cursor)
            calls += 1
            if calls == 1:
                with self.connection() as connection, connection.cursor() as other:
                    other.execute("UPDATE attachments SET lifecycle_state='DELETE_PENDING'")
        with patch.object(paired, "assert_consistent", side_effect=concurrent_change):
            with self.assertRaises(Exception) as captured:
                paired.backup(self.config)
        self.assertEqual("40001", captured.exception.pgcode)
        self.assertEqual(pointer, self.latest())
        self.assertTrue(old.exists())

    def test_insufficient_space_pg_dump_failure_and_interruption_do_not_rotate_old_set(self):
        self.add_object()
        old = paired.backup(self.config)
        pointer = self.latest()
        with self.assertRaises(OSError):
            paired.backup(dataclasses.replace(self.config, min_free_bytes=10**18))
        with self.assertRaises(RuntimeError):
            paired.backup(dataclasses.replace(self.config, pg_dump="/usr/bin/false"))
        with patch.object(paired, "copy_object", side_effect=InterruptedError("test interruption")):
            with self.assertRaises(InterruptedError):
                paired.backup(self.config)
        self.assertEqual(pointer, self.latest())
        self.assertTrue(old.exists())
        paired.verify_set(old)
        self.assertEqual("FAILED", json.loads((self.target / "last-attempt.json").read_text())["status"])

    def test_single_run_lock_and_symlink_source_are_fail_closed(self):
        first = self.add_object()
        lock = os.open(self.target / ".backup.lock", os.O_CREAT | os.O_RDWR, 0o600)
        import fcntl
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with self.assertRaises(BlockingIOError):
                paired.backup(self.config)
        finally:
            os.close(lock)
        original = self.root / "outside"
        first[2].rename(original)
        first[2].symlink_to(original)
        with self.assertRaises(OSError):
            paired.backup(self.config)
        self.assertFalse((self.target / "latest-success.json").exists())

    def test_manifest_tamper_is_detected_on_offline_verify(self):
        self.add_object(compressed=True)
        published = paired.backup(self.config)
        with (published / "objects.jsonl").open("a") as stream:
            stream.write("{}\n")
        with self.assertRaises(ValueError):
            paired.verify_set(published)

    def test_real_cli_sigterm_keeps_previous_success_and_releases_database_locks(self):
        first = self.add_object()
        paired.backup(self.config)
        pointer = self.latest()
        data = b"scanned-original-document\n" * 250000
        digest = hashlib.sha256(data).hexdigest()
        first[2].write_bytes(struct.pack(">8sBqq32s", paired.MAGIC, 0, len(data), len(data), bytes.fromhex(digest)) + data)
        with self.connection() as connection, connection.cursor() as cursor:
            cursor.execute("UPDATE attachments SET sha256=%s,storage_version=%s,size_bytes=%s,stored_size_bytes=%s",
                           (digest, "internal-v1:" + digest, len(data), len(data) + 57))
        config_path = self.root / "backup.json"
        config_path.write_text(json.dumps(dataclasses.asdict(dataclasses.replace(self.config, bytes_per_second=100000))))
        config_path.chmod(0o600)
        process = subprocess.Popen([sys.executable, paired.__file__, "--config", str(config_path)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while not any(self.target.glob(".incomplete-*/media/final/*/*/*")):
                if process.poll() is not None or time.monotonic() >= deadline:
                    self.fail("CLI did not enter bounded copy")
                time.sleep(0.05)
            process.terminate()
            stdout, stderr = process.communicate(timeout=10)
            self.assertNotEqual(0, process.returncode)
            self.assertIn(b"InterruptedError", stderr)
            self.assertEqual(b"", stdout)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
        self.assertEqual(pointer, self.latest())
        attempt = json.loads((self.target / "last-attempt.json").read_text())
        self.assertEqual("FAILED", attempt["status"])
        self.assertEqual(json.loads(pointer)["completed_at"], attempt["lastSuccessAt"])
        with self.connection() as connection, connection.cursor() as cursor:
            cursor.execute("SET LOCAL lock_timeout='1s'")
            cursor.execute("UPDATE attachments SET lifecycle_state='DELETE_PENDING'")

    def test_first_failure_records_unknown_success_without_private_error_fields(self):
        with self.assertRaises(OSError):
            paired.backup(dataclasses.replace(self.config, media_root=str(self.root / "missing-private-path")))
        attempt = json.loads((self.target / "last-attempt.json").read_text())
        self.assertEqual("FAILED", attempt["status"])
        self.assertIsNone(attempt["lastSuccessAt"])
        self.assertIsNotNone(attempt["completedAt"])
        self.assertNotIn("missing-private-path", json.dumps(attempt))
        self.assertNotIn(self.database, json.dumps(attempt))
        self.assertFalse((self.target / "latest-success.json").exists())


def stat_mode(path):
    return path.stat().st_mode & 0o777


if __name__ == "__main__":
    unittest.main()
