import importlib.util
import hashlib
import json
import sqlite3
import tempfile
import time
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "paired_state.py"
SPEC = importlib.util.spec_from_file_location("paired_state", MODULE_PATH)
paired_state = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(paired_state)


class Arguments:
    pass


class PairedStateTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uten-website-state-")
        self.root = Path(self.temporary.name)
        self.live = self.root / "live"
        self.backups = self.root / "backups"
        self.live.mkdir()
        self.backups.mkdir()
        self.database = self.live / "website.db"
        connection = sqlite3.connect(self.database)
        connection.executescript(
            """
            CREATE TABLE _prisma_migrations (
              id TEXT PRIMARY KEY,
              checksum TEXT NOT NULL,
              finished_at TEXT,
              migration_name TEXT NOT NULL,
              rolled_back_at TEXT
            );
            INSERT INTO _prisma_migrations VALUES
              ('one', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', '2026-08-12T00:00:00Z', '20260812000000_initial_production_baseline', NULL);
            CREATE TABLE Setting (id TEXT PRIMARY KEY, key TEXT NOT NULL, i18n TEXT NOT NULL);
            INSERT INTO Setting VALUES ('s1', 'hero', '{"zh":{"image":"/uploads/0123456789abcdef0123456789abcdef.webp"}}');
            CREATE TABLE Series (id TEXT PRIMARY KEY, coverImage TEXT);
            CREATE TABLE SeriesMedia (id TEXT PRIMARY KEY, image TEXT);
            CREATE TABLE Product (id TEXT PRIMARY KEY, image TEXT, gallery TEXT);
            CREATE TABLE ProductVariant (id TEXT PRIMARY KEY, image TEXT, gallery TEXT);
            CREATE TABLE ScenePreset (id TEXT PRIMARY KEY, backgroundImage TEXT);
            CREATE TABLE LegacyMediaAsset (id TEXT PRIMARY KEY, publicPath TEXT);
            CREATE TABLE News (id TEXT PRIMARY KEY, coverImage TEXT);
            CREATE TABLE CaseItem (id TEXT PRIMARY KEY, coverImage TEXT);
            CREATE TABLE WebsiteStateAuthority (
              id TEXT PRIMARY KEY, authorityUuid TEXT UNIQUE NOT NULL,
              mediaGeneration INTEGER NOT NULL DEFAULT 0,
              initializedAt TEXT, createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL
            );
            INSERT INTO WebsiteStateAuthority VALUES
              ('production', '11111111-1111-4111-8111-111111111111', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
            CREATE TABLE WebsiteMediaObject (
              publicPath TEXT PRIMARY KEY, authorityId TEXT NOT NULL,
              sha256 TEXT NOT NULL, sizeBytes INTEGER NOT NULL, state TEXT NOT NULL,
              createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL
            );
            """
        )
        connection.commit()
        connection.close()
        self.uploads = self.live / "uploads"
        self.uploads.mkdir()
        (self.uploads / "0123456789abcdef0123456789abcdef.webp").write_bytes(b"webp-fixture")
        connection = sqlite3.connect(self.database)
        connection.execute(
            "INSERT INTO WebsiteMediaObject VALUES (?, 'production', ?, ?, 'COMMITTED', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
            (
                "/uploads/0123456789abcdef0123456789abcdef.webp",
                hashlib.sha256(b"webp-fixture").hexdigest(),
                len(b"webp-fixture"),
            ),
        )
        connection.commit()
        connection.close()
        self.quiescence = self.root / "quiescence.json"
        self.quiescence.write_bytes(paired_state.canonical_json({
            "database": str(self.database.resolve()),
            "gateClosed": True,
            "nonce": "0" * 32,
            "serviceStopped": True,
            "uploads": str(self.uploads.resolve()),
        }))

    def tearDown(self):
        self.temporary.cleanup()

    def make_snapshot(self):
        arguments = Arguments()
        arguments.database = self.database
        arguments.uploads = self.uploads
        arguments.output = self.backups / "20260812T120000Z-0123456789ab"
        arguments.snapshot_id = arguments.output.name
        arguments.quiescence_receipt = self.quiescence
        paired_state.snapshot(arguments)
        return arguments.output

    def test_snapshot_verify_and_isolated_restore_are_byte_bound(self):
        snapshot = self.make_snapshot()
        manifest = paired_state.verify_snapshot(snapshot)
        self.assertEqual(manifest["uploads"]["fileCount"], 1)
        self.assertEqual(manifest["database"]["prismaMigrationCount"], 1)

        arguments = Arguments()
        arguments.snapshot = snapshot
        arguments.destination = self.root / "restored"
        paired_state.restore(arguments)
        self.assertEqual(
            paired_state.sqlite_evidence(arguments.destination / "website.db"),
            manifest["database"],
        )
        self.assertTrue((arguments.destination / "restore-receipt.json").is_file())

    def test_tampered_media_is_rejected(self):
        snapshot = self.make_snapshot()
        media = snapshot / "uploads" / "0123456789abcdef0123456789abcdef.webp"
        media.write_bytes(b"tampered")
        with self.assertRaisesRegex(paired_state.StateError, "uploads evidence"):
            paired_state.verify_snapshot(snapshot)

    def test_snapshot_requires_exact_quiescence_receipt(self):
        value = json.loads(self.quiescence.read_text())
        value["gateClosed"] = False
        self.quiescence.write_bytes(paired_state.canonical_json(value))
        with self.assertRaisesRegex(paired_state.StateError, "stopped website state"):
            self.make_snapshot()

    def test_live_verification_accepts_complete_prisma_history(self):
        evidence = paired_state.verify_live_database(self.database)
        self.assertEqual(evidence["quickCheck"], "ok")
        self.assertEqual(evidence["prismaMigrationCount"], 1)

    def test_live_verification_rejects_incomplete_prisma_history(self):
        connection = sqlite3.connect(self.database)
        connection.execute(
            "INSERT INTO _prisma_migrations VALUES (?, ?, NULL, ?, NULL)",
            ("two", "def456", "20260813000000_interrupted"),
        )
        connection.commit()
        connection.close()
        with self.assertRaisesRegex(paired_state.StateError, "empty or incomplete"):
            paired_state.verify_live_database(self.database)

    def test_live_history_must_exactly_match_signed_name_and_checksum(self):
        manifest = self.root / "manifest.json"
        connection = sqlite3.connect(self.database)
        try:
            database_schema = paired_state.sqlite_schema_contract(connection)
        finally:
            connection.close()
        manifest.write_bytes(paired_state.canonical_json({
            "databaseSchema": database_schema,
            "migrations": {
                "count": 1,
                "entries": [{
                    "name": "20260812000000_initial_production_baseline",
                    "sha256": "a" * 64,
                    "sizeBytes": 123,
                }],
            },
        }))
        paired_state.verify_live_database(self.database, manifest)
        connection = sqlite3.connect(self.database)
        connection.execute(
            "UPDATE _prisma_migrations SET checksum = ? WHERE id = 'one'",
            ("b" * 64,),
        )
        connection.commit()
        connection.close()
        with self.assertRaisesRegex(paired_state.StateError, "signed migration inventory"):
            paired_state.verify_live_database(self.database, manifest)

    def test_signed_schema_rejects_manual_application_ddl_drift(self):
        connection = sqlite3.connect(self.database)
        try:
            database_schema = paired_state.sqlite_schema_contract(connection)
        finally:
            connection.close()
        manifest = self.root / "schema-manifest.json"
        manifest.write_bytes(paired_state.canonical_json({
            "databaseSchema": database_schema,
            "migrations": {
                "count": 1,
                "entries": [{
                    "name": "20260812000000_initial_production_baseline",
                    "sha256": "a" * 64,
                    "sizeBytes": 123,
                }],
            },
        }))
        connection = sqlite3.connect(self.database)
        connection.execute("CREATE TABLE UnsignedDrift (id TEXT PRIMARY KEY)")
        connection.commit()
        connection.close()
        with self.assertRaisesRegex(paired_state.StateError, "signed sqlite_schema"):
            paired_state.verify_live_database(self.database, manifest)

    def test_signed_schema_includes_custom_objects_attached_to_prisma_history(self):
        connection = sqlite3.connect(self.database)
        try:
            database_schema = paired_state.sqlite_schema_contract(connection)
        finally:
            connection.close()
        manifest = self.root / "history-ddl-manifest.json"
        manifest.write_bytes(paired_state.canonical_json({
            "databaseSchema": database_schema,
            "migrations": {
                "count": 1,
                "entries": [{
                    "name": "20260812000000_initial_production_baseline",
                    "sha256": "a" * 64,
                    "sizeBytes": 123,
                }],
            },
        }))
        connection = sqlite3.connect(self.database)
        connection.execute(
            "CREATE TRIGGER unsigned_prisma_history_trigger "
            "AFTER INSERT ON _prisma_migrations BEGIN "
            "UPDATE Setting SET i18n = i18n WHERE id = 's1'; END"
        )
        connection.commit()
        connection.close()
        with self.assertRaisesRegex(paired_state.StateError, "signed sqlite_schema"):
            paired_state.verify_live_database(self.database, manifest)

    def test_boot_upload_check_has_fixed_metadata_budget_and_never_hashes(self):
        for number in range(5_000):
            (self.uploads / f"{number:032x}.webp").write_bytes(b"x")
        original = paired_state.sha256_file
        paired_state.sha256_file = lambda _path: (_ for _ in ()).throw(AssertionError("boot sample hashed media"))
        started = time.monotonic()
        try:
            evidence = paired_state.bounded_live_upload_check(
                self.uploads, max_entries=128, max_seconds=1.0
            )
        finally:
            paired_state.sha256_file = original
        self.assertLessEqual(evidence["sampledEntries"], 128)
        self.assertFalse(evidence["completeInventory"])
        self.assertLess(time.monotonic() - started, 2.0)

    def test_restored_live_gate_rejects_snapshot_mismatch(self):
        snapshot = self.make_snapshot()
        restore = Arguments()
        restore.snapshot = snapshot
        restore.destination = self.root / "restored-for-live-gate"
        paired_state.restore(restore)
        arguments = Arguments()
        arguments.snapshot = snapshot
        arguments.database = restore.destination / "website.db"
        arguments.uploads = restore.destination / "uploads"
        paired_state.verify_restored_live_command(arguments)
        (arguments.uploads / "0123456789abcdef0123456789abcdef.webp").write_bytes(b"changed")
        with self.assertRaisesRegex(paired_state.StateError, "restored live uploads"):
            paired_state.verify_restored_live_command(arguments)

    def verify_media(self, *, allow_inflight=False, metadata_only=False):
        connection = sqlite3.connect(self.database)
        try:
            return paired_state.verify_media_state(
                connection,
                self.uploads,
                "11111111-1111-4111-8111-111111111111",
                allow_inflight=allow_inflight,
                expected_uid=None,
                expected_gid=None,
                metadata_only=metadata_only,
            )
        finally:
            connection.close()

    def test_media_gate_binds_refs_ledger_authority_and_exact_bytes(self):
        evidence = self.verify_media()
        self.assertEqual(evidence["referenceCount"], 1)
        self.assertEqual(evidence["unreferencedCount"], 0)
        self.assertEqual(evidence["verificationMode"], "full-bytes")
        media = self.uploads / "0123456789abcdef0123456789abcdef.webp"
        media.write_bytes(b"other-bytes!")
        with self.assertRaisesRegex(paired_state.StateError, "bytes differ"):
            self.verify_media()

    def test_media_gate_rejects_untracked_file_and_wrong_authority(self):
        (self.uploads / "fedcba9876543210fedcba9876543210.webp").write_bytes(b"orphan")
        with self.assertRaisesRegex(paired_state.StateError, "no database ledger"):
            self.verify_media()
        (self.uploads / "fedcba9876543210fedcba9876543210.webp").unlink()
        with self.assertRaisesRegex(paired_state.StateError, "authority UUID"):
            connection = sqlite3.connect(self.database)
            try:
                paired_state.verify_media_state(
                    connection,
                    self.uploads,
                    "22222222-2222-4222-8222-222222222222",
                    allow_inflight=False,
                    expected_uid=None,
                    expected_gid=None,
                )
            finally:
                connection.close()

    def test_pending_media_is_boot_blocking_but_bounded_active_scan_tolerates_it(self):
        pending_path = "/uploads/fedcba9876543210fedcba9876543210.webp"
        connection = sqlite3.connect(self.database)
        connection.execute(
            "INSERT INTO WebsiteMediaObject VALUES (?, 'production', ?, ?, 'PENDING', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
            (pending_path, "b" * 64, 10),
        )
        connection.commit()
        connection.close()
        with self.assertRaisesRegex(paired_state.StateError, "PENDING"):
            self.verify_media()
        evidence = self.verify_media(allow_inflight=True, metadata_only=True)
        self.assertEqual(evidence["pendingCount"], 1)


if __name__ == "__main__":
    unittest.main()
