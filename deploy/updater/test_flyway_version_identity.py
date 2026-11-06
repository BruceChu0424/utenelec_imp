"""Sole Main fixtures and Task pure consumers; never operate a real host."""
from __future__ import annotations
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FORMAL_FIXTURE = ROOT / "contracts/flyway-version/fixtures.json"

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec); sys.modules[name] = module
    spec.loader.exec_module(module); return module

guard = load("flyway_contract_guard", ROOT / "deploy/updater/release_guard.py")
tools = load("flyway_contract_tools", ROOT / "deploy/release/release_tools.py")
repo2 = load("pgbackrest_repo2", ROOT / "deploy/postgres/backup/pgbackrest_repo2.py")
health = load("flyway_contract_health", ROOT / "deploy/postgres/backup/pgbackrest_health.py")
acceptance = load("flyway_contract_acceptance", ROOT / "deploy/postgres/backup/backup_acceptance.py")

def sample_rows(compound=True):
    entries = [("999", "V999__base.sql"),
               *([("999.1", "V999_1__one.sql"), ("999.10", "V999_10__ten.sql")] if compound else []),
               ("1070", "V1070__head.sql")]
    return [{"installedRank": index + 1, "version": version,
             "description": filename.split("__", 1)[1][:-4].replace("_", " "), "type": "SQL",
             "script": filename, "checksum": index + 11, "success": True}
            for index, (version, filename) in enumerate(entries)]

def tsv(rows):
    return "".join(f"{r['version']}\t{r['script']}\t{r['checksum']}\n" for r in rows)

class FlywayVersionIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # One current authority; the older broad01/mixed-filename fixture is
        # retained only in historical evidence and is not a selectable fallback.
        cls.contract = json.loads(FORMAL_FIXTURE.read_text("utf-8"))

    def test_canonical_parts_retain_every_component_and_arbitrary_precision(self):
        for value in self.contract["canonicalOrder"]:
            with self.subTest(version=value):
                self.assertEqual(tuple(map(str, guard.parse_flyway_version(value))), tuple(value.split(".")))
        for value in self.contract["invalidCanonical"]:
            with self.subTest(invalid=value), self.assertRaises(ValueError): guard.parse_flyway_version(value)

    def test_filename_aliases_are_normalized_without_rewriting_the_filename(self):
        for case in self.contract["scripts"]:
            with self.subTest(filename=case["file"]):
                self.assertEqual(guard.flyway_version_from_filename(case["file"]), case["version"])
        for value in self.contract["invalidScripts"]:
            with self.subTest(invalid=value), self.assertRaises(ValueError): guard.flyway_version_from_filename(value)

    def test_tuple_order_and_integer_receipt_head_never_concatenate_or_truncate(self):
        values = self.contract["canonicalOrder"]
        self.assertEqual(sorted(reversed(values), key=guard.parse_flyway_version), values)
        self.assertNotEqual(guard.parse_flyway_version("999.1"), guard.parse_flyway_version("999.10"))
        self.assertEqual(guard.require_integer_flyway_head(["999", "999.10", "1000"]), 1000)
        with self.assertRaises(ValueError): guard.require_integer_flyway_head(["999", "999.10"])
        self.assertEqual(guard.flyway_inventory_head(["999", "999.10"]), "999.10")
        self.assertIs(type(guard.flyway_inventory_head(["999", "1000"])), int)

    def test_raw_history_is_bound_to_its_script_without_rewriting_original_text(self):
        for case in self.contract["legacyHistory"]:
            with self.subTest(case=case):
                self.assertEqual(guard.flyway_raw_version_from_filename(case["file"]), case["raw"])
                for observed in (case["raw"], case["canonical"]):
                    self.assertEqual(guard.validate_flyway_history_version(observed, case["file"]), guard.parse_flyway_version(case["canonical"]))
        for case in self.contract["scripts"]:
            self.assertEqual(guard.flyway_history_description_from_filename(case["file"], case["rawDescription"]), case["flywayDescription"])
            with self.assertRaises(ValueError): guard.flyway_history_description_from_filename(case["file"], "forged description")
        for observed, script in [("001", "V01__enable_pgcrypto.sql"), ("01", "V01__forged.sql"), ("1.0", "V01__enable_pgcrypto.sql")]:
            with self.subTest(observed=observed, script=script), self.assertRaises(ValueError): guard.validate_flyway_history_version(observed, script)

    def test_signed_inventory_and_source_metadata_include_compound_versions(self):
        rows = sample_rows()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); migrations = root / "migrations"; migrations.mkdir()
            for row in rows: (migrations / row["script"]).write_text("SELECT 1;\n", encoding="utf-8")
            checksums = root / "checksums.tsv"
            checksums.write_text(tools.FLYWAY_CHECKSUM_HEADER + "\n" + tsv(rows), encoding="utf-8", newline="\n")
            result = tools.migration_metadata(migrations, checksums)
        self.assertEqual([r["version"] for r in result["migrations"]], ["999", "999.1", "999.10", "1070"])
        self.assertEqual(result["headVersion"], "1070"); self.assertEqual(result["migrationCount"], 4)
        self.assertEqual(result["migrations"][2]["file"], "V999_10__ten.sql")
        self.assertEqual(guard.validate_flyway(result)["migrations"], result["migrations"])

    def test_duplicate_canonical_filename_identities_and_noncanonical_order_are_rejected(self):
        raw = "999.1\tV999_1__one.sql\t1\n999.1\tV999.1__other.sql\t2\n"
        with self.assertRaises(ValueError): guard.canonical_flyway_rows(raw)
        with self.assertRaises(ValueError): guard.canonical_flyway_rows(tsv(list(reversed(sample_rows()))), require_order=True)

    def test_backup_health_and_signed_acceptance_keep_exact_head_count_and_projection(self):
        rows = sample_rows(); identity = health._flyway_identity(rows); raw = tsv(rows).encode()
        self.assertEqual(identity["headVersion"], 1070); self.assertIs(type(identity["headVersion"]), int)
        self.assertEqual(identity["successfulMigrationCount"], 4)
        self.assertEqual(identity["signedProjectionSha256"], hashlib.sha256(raw).hexdigest())
        observed = {"databaseIdentity": {"flyway": identity}}
        self.assertEqual(acceptance.validate_signed_flyway_rows(raw, observed, "1070", 4), hashlib.sha256(raw).hexdigest())
        with self.assertRaises(acceptance.ContractError): acceptance.validate_signed_flyway_rows(raw.replace(b"999.10\t", b"999.1\t"), observed, "1070", 4)

    def test_typed_compound_maximum_and_aliases_keep_main_backup_receipt_contract(self):
        for value in ("999.01", "999.10.0", "999_10", "١"):
            rows = sample_rows(); rows[0]["version"] = value
            with self.subTest(value=value), self.assertRaises(health.ContractError): health._flyway_identity(rows)
        compound = health._flyway_identity(sample_rows()[:-1])
        self.assertEqual(compound["headVersion"], "999.10"); self.assertIs(type(compound["headVersion"]), str)

    def test_padded_history_digest_and_canonical_signed_tsv_remain_separate(self):
        rows = sample_rows(); rows[0].update(version="01", script="V01__enable_pgcrypto.sql", description="enable pgcrypto")
        original_history = tsv(rows).encode(); signed = original_history.replace(b"01\tV01__", b"1\tV01__")
        identity = health._flyway_identity(rows)
        self.assertEqual(rows[0]["version"], "01")
        self.assertEqual(identity["headVersion"], 1070)
        self.assertEqual(identity["signedProjectionSha256"], hashlib.sha256(signed).hexdigest())
        self.assertNotEqual(hashlib.sha256(original_history).hexdigest(), identity["signedProjectionSha256"])
        self.assertEqual(acceptance.validate_signed_flyway_rows(signed, {"databaseIdentity": {"flyway": identity}}, "1070", 4), hashlib.sha256(signed).hexdigest())
        duplicate = [dict(rows[0]), dict(rows[0], version="1", installedRank=2), dict(rows[-1], installedRank=3)]
        with self.assertRaises(health.ContractError): health._flyway_identity(duplicate)

    def test_isolated_shell_consumer_sorts_with_the_public_guard_and_rejects_aliases(self):
        rows = sample_rows(); python = sys.executable if Path(sys.executable).is_file() else shutil.which("python")
        self.assertIsNotNone(python)
        command = [python, "-I", str(ROOT / "deploy/updater/release_guard.py"), "flyway-rows"]
        result = subprocess.run(command, input=tsv(list(reversed(rows))).encode(), capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr.decode()); self.assertEqual(result.stdout.decode().replace("\r\n", "\n"), tsv(rows))
        result = subprocess.run(command + ["--summary", "--require-order"], input=tsv(rows).encode(), capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr.decode()); self.assertEqual(result.stdout.decode().strip(), "4\t1070")
        for invalid in [tsv(rows).replace("999.10\t", "999.010\t"), tsv(rows).replace("999\tV999__base.sql", "0999\tV0999__base.sql")]:
            result = subprocess.run(command + ["--history"], input=invalid.encode(), capture_output=True, check=False)
            self.assertNotEqual(result.returncode, 0); self.assertEqual(result.stdout, b"")
        legacy = tsv(rows).replace("999\tV999__base.sql", "01\tV01__enable_pgcrypto.sql")
        result = subprocess.run(command + ["--history"], input=legacy.encode(), capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertTrue(result.stdout.decode().replace("\r\n", "\n").startswith("1\tV01__enable_pgcrypto.sql\t"))

    @unittest.skipUnless(os.name == "posix", "actual pinned runtime loader runs in the private Linux suite")
    def test_posix_runtime_consumers_preserve_raw_history_and_bind_signed_descriptions(self):
        boot = load("contract_runtime_boot", ROOT / "deploy/updater/runtime_boot_verifier.py")
        updater = load("contract_runtime_updater", ROOT / "deploy/updater/release_updater.py")
        rows = sample_rows(); rows[0].update(version="01", script="V01__enable_pgcrypto.sql", description="enable pgcrypto")
        target = {"flywayMigrations": [{"version": guard.flyway_version_from_filename(r["script"]), "file": r["script"], "flywayChecksum": r["checksum"], "description": r["script"].split("__", 1)[1][:-4]} for r in rows]}
        expected = health._flyway_identity(rows)
        self.assertEqual(boot._canonical_live_flyway(rows, target, guard), expected)
        self.assertEqual(updater.canonical_live_flyway_identity(rows, target), expected)
        self.assertEqual(updater.expected_signed_history_projection(target), updater.canonical_signed_flyway_projection(target))
        self.assertNotEqual(updater.expected_signed_history_projection(target), tsv(rows).encode())
        for field, value in (("version", "001"), ("description", "forged description")):
            changed = [dict(r) for r in rows]; changed[0][field] = value
            with self.subTest(field=field):
                with self.assertRaises(boot.BootVerificationError): boot._canonical_live_flyway(changed, target, guard)
                with self.assertRaises(updater.UpdaterError): updater.canonical_live_flyway_identity(changed, target)

if __name__ == "__main__": unittest.main()
