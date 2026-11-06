"""Synthetic signed-row contracts; never invokes installation, backup or activation."""

import copy
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
for directory in ("deploy/release", "deploy/updater", "deploy/postgres/backup"):
    sys.path.insert(0, str(ROOT / directory))

CASES = (
    ("998", "V998__base_schema.sql", "base schema", -(2**31)),
    ("999", "V999__integer_head.sql", "integer head", 0),
    ("999.1", "V999_1__first_decimal.sql", "first decimal", 2**31 - 1),
    ("999.2", "V999_2__second_decimal.sql", "second decimal", -17),
    ("999.10", "V999_10__tenth_decimal.sql", "tenth decimal", 18),
    ("1000", "V1000__after_decimal.sql", "after decimal", -19),
)


@unittest.skipUnless(os.name == "posix", "trusted standalone runtime is POSIX")
class FlywayEndToEndTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import release_tools
        import release_guard
        import release_updater
        import runtime_boot_verifier
        import pgbackrest_health
        import backup_acceptance
        import recovery_commit_boot_verifier
        import retention_launcher
        cls.tools = release_tools
        cls.guard = release_guard
        cls.updater = release_updater
        cls.boot = runtime_boot_verifier
        cls.health = pgbackrest_health
        cls.acceptance = backup_acceptance
        cls.recovery = recovery_commit_boot_verifier
        cls.retention = retention_launcher.load_runtime(
            release_updater_path=ROOT / "deploy/updater/release_updater.py",
            retention_manager_path=ROOT / "deploy/updater/retention_manager.py",
            pins=retention_launcher.RuntimePins(
                retention_launcher.APPROVED_RELEASE_UPDATER_SHA256,
                retention_launcher.APPROVED_RETENTION_MANAGER_SHA256,
            ),
            require_root_control=False,
        )

    def fixture(self, cases=CASES):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        migrations = root / "migrations"
        migrations.mkdir()
        for _, filename, _, _ in reversed(cases):
            (migrations / filename).write_text("SELECT 1;\n", encoding="utf-8")
        checksum = root / "checksums.tsv"
        checksum.write_text(self.tools.FLYWAY_CHECKSUM_HEADER + "\n" + "".join(
            f"{version}\t{filename}\t{crc}\n" for version, filename, _, crc in cases
        ), encoding="utf-8")
        metadata = self.tools.migration_metadata(migrations, checksum)
        validated = self.guard.validate_flyway(metadata)
        info = {"flywayHeadVersion": validated["headVersion"], "flywayMigrations": validated["migrations"]}
        rows = [{
            "checksum": crc, "description": description, "installedRank": index,
            "script": filename, "success": True, "type": "SQL", "version": version,
        } for index, (version, filename, description, crc) in enumerate(cases, 1)]
        return root, migrations, checksum, metadata, info, rows

    def identities(self, rows, info):
        return (
            self.boot._canonical_live_flyway(rows, info),
            self.updater.canonical_live_flyway_identity(rows, info),
            self.health._flyway_identity(rows),
        )

    def test_dot_rows_builder_guard_boot_updater_and_backup_have_one_identity(self):
        _, _, _, metadata, info, rows = self.fixture()
        before = copy.deepcopy(rows)
        identities = self.identities(rows, info)
        self.assertEqual([case[0] for case in CASES], [row["version"] for row in metadata["migrations"]])
        self.assertEqual("1000", metadata["headVersion"])
        for identity in identities:
            self.assertEqual(identities[0], identity)
            self.assertIs(type(identity["headVersion"]), int)
            self.assertEqual(1000, identity["headVersion"])
        signed = self.updater.canonical_signed_flyway_projection(info)
        report = {"databaseIdentity": {"flyway": identities[0]}}
        self.assertEqual(hashlib.sha256(signed).hexdigest(), self.acceptance.validate_signed_flyway_rows(signed, report, "1000", len(rows)))
        self.assertEqual(before, rows)

    def test_dot_head_never_becomes_a_float_and_legacy_integer_projection_is_unchanged(self):
        _, _, _, _, info, rows = self.fixture(CASES[:-1])
        for identity in self.identities(rows, info):
            self.assertEqual("999.10", identity["headVersion"])
            self.assertIs(type(identity["headVersion"]), str)
        _, _, _, _, old_info, old_rows = self.fixture(CASES[:2])
        expected_history = hashlib.sha256(json.dumps(old_rows, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")).hexdigest()
        for identity in self.identities(old_rows, old_info):
            self.assertEqual(999, identity["headVersion"])
            self.assertIs(type(identity["headVersion"]), int)
            self.assertEqual(expected_history, identity["canonicalHistorySha256"])

    def test_published_legacy_raw_rows_keep_their_hash_and_bind_canonical_signed_versions(self):
        legacy=("1","V01__enable_pgcrypto.sql","enable pgcrypto",123)
        _,_,_,metadata,info,rows=self.fixture((legacy,*CASES))
        rows[0]["version"]="01"
        original=copy.deepcopy(rows)
        raw_hash=hashlib.sha256(json.dumps(rows,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()
        projection=self.updater.canonical_signed_flyway_projection(info)
        for identity in self.identities(rows,info):
            self.assertEqual(raw_hash,identity["canonicalHistorySha256"])
            self.assertEqual(hashlib.sha256(projection).hexdigest(),identity["signedProjectionSha256"])
            self.assertEqual(1000,identity["headVersion"])
        self.assertTrue(projection.startswith(b"1\tV01__enable_pgcrypto.sql\t123\n"))
        self.assertEqual(original,rows)
        for raw in ("001","02","1.0"):
            forged=copy.deepcopy(rows);forged[0]["version"]=raw
            with self.assertRaises(self.boot.BootVerificationError): self.boot._canonical_live_flyway(forged,info)
            with self.assertRaises(self.updater.UpdaterError): self.updater.canonical_live_flyway_identity(forged,info)
            with self.assertRaises(self.health.ContractError): self.health._flyway_identity(forged)
        forged=copy.deepcopy(metadata);forged["migrations"][0]["version"]="01"
        with self.assertRaises(self.guard.ReleaseGuardError): self.guard.validate_flyway(forged)

    def test_semantic_append_only_extension_retains_every_exact_signed_row(self):
        _, _, _, _, current, _ = self.fixture(CASES[:4])
        _, _, _, _, dotted, _ = self.fixture(CASES[:5])
        _, _, _, _, target, _ = self.fixture()
        self.updater.require_append_only_flyway_transition(current, dotted)
        self.updater.require_append_only_flyway_transition(dotted, target)
        with self.assertRaises(self.updater.UpdaterError):
            self.updater.require_append_only_flyway_transition(dotted, current)
        changed = copy.deepcopy(target)
        changed["flywayMigrations"][0]["flywayChecksum"] += 1
        with self.assertRaises(self.updater.UpdaterError):
            self.updater.require_append_only_flyway_transition(current, changed)

    def test_alias_duplicate_disordered_and_forged_live_rows_fail_in_every_owner(self):
        _, _, _, _, info, rows = self.fixture()
        changed = []
        for version in ("999.01", "999.1.0", "999_1", "1e3", "١", "", True):
            value = copy.deepcopy(rows);value[2]["version"] = version;changed.append(value)
        value = copy.deepcopy(rows);value[2]["version"] = "999";changed.append(value)
        value = copy.deepcopy(rows);value[2],value[3] = value[3],value[2]
        for index, row in enumerate(value, 1): row["installedRank"] = index
        changed.append(value)
        for field, forged in (("script", "V999_2__first_decimal.sql"), ("description", "first  decimal"), ("checksum", True), ("checksum", 1.0), ("checksum", 2**31), ("success", False), ("type", "BASELINE")):
            value = copy.deepcopy(rows);value[2][field] = forged;changed.append(value)
        engines = (
            (lambda value:self.boot._canonical_live_flyway(value, info), self.boot.BootVerificationError),
            (lambda value:self.updater.canonical_live_flyway_identity(value, info), self.updater.UpdaterError),
            (self.health._flyway_identity, self.health.ContractError),
        )
        for index, value in enumerate(changed):
            for engine, error in engines:
                with self.subTest(case=index, owner=error.__name__), self.assertRaises(error): engine(value)

    def test_signed_crc_and_description_cannot_be_changed_under_the_same_script(self):
        _, _, _, _, info, rows = self.fixture()
        for field, forged in (("flywayChecksum", 7), ("flywayChecksum", True), ("description", "forged description")):
            changed = copy.deepcopy(info);changed["flywayMigrations"][2][field] = forged
            with self.subTest(field=field), self.assertRaises(self.boot.BootVerificationError): self.boot._canonical_live_flyway(rows, changed)
            with self.subTest(field=field), self.assertRaises(self.updater.UpdaterError): self.updater.canonical_live_flyway_identity(rows, changed)

    def test_checksum_export_and_backup_projection_reject_wrong_order_aliases_and_crc_drift(self):
        _, _, checksum, _, info, rows = self.fixture()
        original = checksum.read_text(encoding="utf-8")
        malformed = (
            original.replace("999.1\t", "999.01\t"),
            original.replace("999.1\t", "999.1.0\t"),
            original.replace("V999_1__", "V999_2__"),
            original + "999.10\tV999.10__another.sql\t8\n",
        )
        for raw in malformed:
            checksum.write_text(raw, encoding="utf-8")
            with self.assertRaises(self.tools.ReleaseMetadataError): self.tools.read_flyway_checksums(checksum)
        projection = self.updater.canonical_signed_flyway_projection(info)
        report = {"databaseIdentity": {"flyway": self.identities(rows, info)[0]}}
        for raw in (projection.replace(b"999.1\t", b"999.01\t"), projection.replace(b"999.1\t", b"999.1.0\t"), projection.replace(b"2147483647\n", b"2147483646\n"), b"\xef\xbb\xbf"+projection, projection.replace(b"\n", b"\r\n")):
            with self.assertRaises(self.acceptance.ContractError): self.acceptance.validate_signed_flyway_rows(raw, report, "1000", len(rows))

    def test_real_jar_entries_bind_the_exact_dot_migrations_in_both_layouts(self):
        root, migrations, _, metadata, _, _ = self.fixture()
        for name, prefix in (("uten-imp-server.jar", "BOOT-INF/classes/db/migration/"), ("uten-imp-migrator.jar", "db/migration/")):
            path = root / name
            def write(tamper=False):
                with zipfile.ZipFile(path, "w") as jar:
                    if "migrator" in name:
                        jar.writestr("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\r\nMain-Class: com.uten.imp.migration.UtenImpMigrator\r\n\r\n")
                        for entry in self.tools.MIGRATOR_APPLICATION_CLASSES: jar.writestr(entry, b"synthetic-bytecode")
                    for migration in metadata["migrations"]:
                        data = (migrations / migration["file"]).read_bytes()
                        if tamper and migration["version"] == "999.1": data += b"-- forged\n"
                        jar.writestr(prefix+migration["file"], data)
            write();self.tools.verify_jar_migrations(path, metadata)
            write(True)
            with self.assertRaises(self.tools.ReleaseMetadataError): self.tools.verify_jar_migrations(path, metadata)

    def test_dot_live_identity_passes_boot_recovery_and_retention_without_rewriting_input(self):
        _, _, _, _, info, rows = self.fixture(CASES[:-1])
        identity = self.identities(rows, info)[0]
        database_identity = {**identity, "systemIdentifier": "7523456789012345678", "timeline": 1}
        self.boot._validate_database_identity(database_identity, "synthetic database")
        evidence = {
            "databaseName": "uten_imp", "dataDirectory": "/data/postgresql/16/main",
            "schemaName": "public", "serverPort": 5432, "serverVersionNum": 160015,
            "systemdMainPid": 1234, "systemIdentifier": "7523456789012345678", "timeline": 1,
            "verifiedAtUtc": "2026-11-05T00:00:00Z", "verifierSha256": self.updater.DATABASE_RECOVERY_VERIFIER_SHA256,
            "flyway": identity,
        }
        original = copy.deepcopy(evidence)
        self.recovery.validate_live_database_evidence(evidence)
        self.retention.validate_recovery_live_database_evidence(evidence)
        self.assertEqual(original, evidence)
        for forged in (True, 999.1, "999.01", "999_1", "999.10.0"):
            changed = copy.deepcopy(database_identity);changed["headVersion"] = forged
            with self.assertRaises(self.boot.BootVerificationError): self.boot._validate_database_identity(changed, "synthetic database")

    @unittest.skipIf(getattr(os, "geteuid", lambda: -1)() == 0, "signed restore fixture intentionally runs without root authority")
    def test_real_signature_binds_dot_manifest_both_jars_and_backup_rows_before_any_output(self):
        from test_release_security import ReleaseFixture
        fixture = ReleaseFixture(methodName="runTest")
        fixture.setUp();self.addCleanup(fixture.tearDown)
        cases=(("1","V01__enable_pgcrypto.sql","enable pgcrypto",123),*CASES[:-1])
        for path in fixture.migrations.iterdir(): path.unlink()
        for _, filename, _, _ in cases: (fixture.migrations / filename).write_text("SELECT 1;\n", encoding="utf-8")
        fixture.flyway_checksums.write_text(self.tools.FLYWAY_CHECKSUM_HEADER+"\n"+"".join(f"{version}\t{filename}\t{crc}\n" for version,filename,_,crc in cases),encoding="utf-8")
        metadata = self.tools.migration_metadata(fixture.migrations,fixture.flyway_checksums)
        for name,prefix in (("uten-imp-server.jar","BOOT-INF/classes/db/migration/"),("uten-imp-migrator.jar","db/migration/")):
            with zipfile.ZipFile(fixture.payload / "server" / name,"w") as jar:
                if "migrator" in name:
                    jar.writestr("META-INF/MANIFEST.MF","Manifest-Version: 1.0\r\nMain-Class: com.uten.imp.migration.UtenImpMigrator\r\n\r\n")
                    for entry in self.tools.MIGRATOR_APPLICATION_CLASSES: jar.writestr(entry,b"synthetic-bytecode")
                for row in metadata["migrations"]: jar.write(fixture.migrations/row["file"],prefix+row["file"])
        self.tools.write_checksums(fixture.payload,fixture.payload/"SHA256SUMS")
        with tarfile.open(fixture.artifact,"w:gz") as bundle: bundle.add(fixture.payload,arcname=fixture.version,recursive=True)
        key=fixture.root/"ephemeral-signing-key"
        ssh=shutil.which("ssh-keygen")
        self.assertIsNotNone(ssh)
        subprocess.run([ssh,"-q","-t","ed25519","-N","","-f",str(key)],check=True,capture_output=True)
        allowed=fixture.root/"allowed-signers"
        public=" ".join(key.with_suffix(".pub").read_text(encoding="ascii").split()[:2])
        allowed.write_text(self.guard.SIGNING_IDENTITY+" "+public+"\n",encoding="ascii")
        key_id=next(iter(self.guard.allowed_signing_key_ids(allowed)))
        self.tools.build_manifest(SimpleNamespace(
            artifact=fixture.artifact,artifact_object_key=f"releases/{fixture.version}/{fixture.artifact.name}",
            built_at="2026-08-11T08:00:00Z",commit=fixture.commit,flyway_dir=fixture.migrations,
            flyway_checksums=fixture.flyway_checksums,output=fixture.manifest_path,payload_root=fixture.payload,
            signing_key_id=key_id,source_ref=f"refs/tags/{fixture.version}",version=fixture.version,
        ))
        subprocess.run([ssh,"-Y","sign","-f",str(key),"-n",self.guard.SIGNATURE_NAMESPACE,str(fixture.manifest_path)],check=True,capture_output=True)
        argv=["release_guard.py","verified-flyway-checksums","--manifest",str(fixture.manifest_path),"--signature",str(fixture.manifest_path.with_suffix(".json.sig")),"--allowed-signers",str(allowed),"--expected-version",fixture.version]
        output=io.StringIO()
        with mock.patch.object(sys,"argv",argv),contextlib.redirect_stdout(output): self.assertEqual(0,self.guard.main())
        expected="".join(f"{version}\t{filename}\t{crc}\n" for version,filename,_,crc in cases)
        self.assertEqual(expected,output.getvalue())
        signed=json.loads(fixture.manifest_path.read_text(encoding="utf-8"))
        info=self.guard.validate_manifest(signed)
        rows=[{"checksum":crc,"description":description,"installedRank":i,"script":filename,"success":True,"type":"SQL","version":version} for i,(version,filename,description,crc) in enumerate(cases,1)]
        rows[0]["version"]="01"
        identity=self.identities(rows,info)[0]
        self.assertEqual("999.10",identity["headVersion"])
        self.acceptance.validate_signed_flyway_rows(output.getvalue().encode(),{"databaseIdentity":{"flyway":identity}},"999.10",len(cases))
        signed["flyway"]["migrations"][2]["flywayChecksum"]+=1
        self.tools.write_json(fixture.manifest_path,signed)
        leaked=io.StringIO();errors=io.StringIO()
        with mock.patch.object(sys,"argv",argv),contextlib.redirect_stdout(leaked),contextlib.redirect_stderr(errors): self.assertEqual(2,self.guard.main())
        self.assertEqual("",leaked.getvalue())


if __name__ == "__main__":
    unittest.main()
