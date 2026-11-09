"""Source-bound caller contracts; no importer or role hardener is executed."""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import verify_candidate
from legacy_test_sources import copy_reviewed_shared_sources


ROOT = Path(__file__).resolve().parents[2]
SHELLS = (ROOT / "server/legacy_migration/migrate.sh",
          ROOT / "deploy/setup/harden-existing-postgres-roles.sh")


class CandidateVersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.legacy = self.root / "server/legacy_migration"
        self.legacy.mkdir(parents=True)
        for name in ("migrate.sh", "export_legacy.ps1", "verify_candidate.py", "reconcile_modules.py",
                     "compose_bootstrap.py", "prepare_source_authority.py", "prepare_hr_keys.py",
                     "cleanup_hr_keep_admin.sql", "warehouse_crosswalk.csv"):
            (self.legacy / name).write_text("synthetic controlled input\n", encoding="utf-8")
        (self.legacy / "mapping-version.txt").write_text("bootstrap-v3\n", encoding="ascii")
        self.migrations = self.root / "server/src/main/resources/db/migration"
        self.migrations.mkdir(parents=True)
        self.manifest = self.root / "checksums.tsv"

    def prepare(self, rows):
        copy_reviewed_shared_sources(self.root)
        for _, name in reversed(rows):
            (self.migrations / name).write_bytes(b"\xef\xbb\xbfSELECT 1;\r\n")
        for arguments in (("init", "-q"), ("config", "user.name", "Synthetic fixture"),
                          ("config", "user.email", "fixture@example.invalid"),
                          ("config", "core.autocrlf", "false"), ("add", "."),
                          ("commit", "-qm", "Freeze synthetic reviewed inputs")):
            subprocess.run(["git", *arguments], cwd=self.root, check=True, capture_output=True)
        self.manifest.write_text("# uten-imp-flyway-checksums-v1\n" + "".join(
            f"{version}\t{name}\t{verify_candidate.flyway_checksum((self.migrations / name).read_bytes())}\n"
            for version, name in rows), encoding="utf-8")

    def test_component_order_script_binding_and_old_integer_head_are_preserved(self):
        rows = [("1", "V01__enable_pgcrypto.sql"), ("2", "V2__first.sql"), ("999", "V999__whole.sql"),
                ("999.1", "V999_1__first_dot.sql"), ("999.2", "V999_2__second_dot.sql"),
                ("999.11", "V999.11__eleventh_dot.sql"), ("1000", "V1000__next.sql")]
        self.prepare(rows)
        self.assertEqual((7, 1000, "bootstrap-v3"), verify_candidate.verify(self.root, self.manifest))
        self.manifest.write_text(self.manifest.read_text().replace("V999_2__second_dot.sql", "V999_2__different.sql"))
        with self.assertRaisesRegex(ValueError, "exact reviewed"):
            verify_candidate.verify(self.root, self.manifest)

    def test_large_component_and_dotted_head_are_never_int32_or_float(self):
        self.prepare([("999.11", "V999_11__prior.sql"),
                      ("3000000000.1", "V3000000000_1__large.sql")])
        self.assertEqual((2, "3000000000.1", "bootstrap-v3"),
                         verify_candidate.verify(self.root, self.manifest))

    def test_semantic_duplicate_script_aliases_are_rejected(self):
        self.prepare([("999.1", "V999_1__underscore.sql"), ("999.1", "V999.1__dot.sql")])
        with self.assertRaisesRegex(ValueError, "duplicate"):
            verify_candidate.verify(self.root, self.manifest)

    def test_source_drift_and_crc_changes_still_fail(self):
        self.prepare([("1", "V1__first.sql")])
        original = self.manifest.read_text()
        prefix, checksum = original.rstrip("\n").rsplit("\t", 1)
        self.manifest.write_text(prefix + "\t" + str(int(checksum) ^ 1) + "\n")
        with self.assertRaisesRegex(ValueError, "exact reviewed"):
            verify_candidate.verify(self.root, self.manifest)
        self.manifest.write_text(original)
        (self.migrations / "V1__first.sql").write_text("SELECT 2;\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "uncommitted"):
            verify_candidate.verify(self.root, self.manifest)


@unittest.skipIf(os.name == "nt", "POSIX fd3 helpers are exercised in the Linux tool job")
class StandaloneVersionTests(unittest.TestCase):
    def invoke(self, path, arguments, rows="", suffix="flyway_contract \"$@\" 3<&0\n"):
        source = path.read_text(encoding="utf-8")
        start = source.index("flyway_contract() {")
        end = source.index("\nPY\n}\n", start) + len("\nPY\n}\n")
        program = "set -euo pipefail\n" + source[start:end]
        if "flyway_at_least" in suffix:
            start = source.index("flyway_at_least() {")
            end = source.index("\n}\n", start) + len("\n}\n")
            program += "\ndie() { exit 91; }\n" + source[start:end]
        program += "\n" + suffix
        return subprocess.run(["bash", "-c", program, "caller-test", *arguments], input=rows,
                              text=True, capture_output=True, cwd=tempfile.gettempdir())

    def test_both_generated_callers_keep_component_order_and_exact_tsv_fields(self):
        rows = "999\tV999__base.sql\t1\n999.2\tV999_2__second.sql\t-2\n999.11\tV999_11__eleventh.sql\t3\n"
        for shell in SHELLS:
            with self.subTest(shell=shell):
                result = self.invoke(shell, ["summary"], rows)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual("3\t999.11\n", result.stdout)

    def test_only_attested_original_legacy_history_can_project_to_canonical_wire(self):
        for shell in SHELLS:
            for raw in ("01", "1"):
                result = self.invoke(shell, ["history"], f"{raw}\tV01__enable_pgcrypto.sql\t1\n")
                self.assertEqual((0, "1\tV01__enable_pgcrypto.sql\t1\n"), (result.returncode, result.stdout), result.stderr)
            for row in ("001\tV01__enable_pgcrypto.sql\t1\n", "01\tV01__forged.sql\t1\n", "01\tV1__other.sql\t1\n"):
                self.assertNotEqual(0, self.invoke(shell, ["history"], row).returncode)
            self.assertNotEqual(0, self.invoke(shell, ["summary"], "01\tV01__enable_pgcrypto.sql\t1\n").returncode)

    def test_aliases_wrong_binding_unsorted_rows_and_bad_crc_cannot_authorize(self):
        for rows in ("999.01\tV999_1__bad.sql\t1\n", "999.1\tV999_2__wrong.sql\t1\n",
                     "999.11\tV999_11__later.sql\t1\n999.2\tV999_2__earlier.sql\t1\n",
                     "1e3\tV1000__not_exponent.sql\t1\n", "1\tV1__bad.sql\t2147483648\n",
                     "1\tV1__first.sql\t1\n1\tV1__other.sql\t1\n", "", "1\tV1__bad.sql\t1\textra\n"):
            for shell in SHELLS:
                with self.subTest(shell=shell, rows=rows):
                    self.assertNotEqual(0, self.invoke(shell, ["summary"], rows).returncode)

    def test_large_inventory_uses_fd3_and_never_evaluates_filename_text(self):
        rows = "".join(f"{i}\tV{i}__{'x' * 150}.sql\t0\n" for i in range(1, 2001))
        self.assertGreater(len(rows), 131072)
        for shell in SHELLS:
            result = self.invoke(shell, ["summary"], rows)
            self.assertEqual((0, "2000\t2000\n"), (result.returncode, result.stdout), result.stderr)
            result = self.invoke(shell, ["summary"], "1\tV1__$(exit 79).sql\t0\n")
            self.assertEqual((0, "1\t1\n"), (result.returncode, result.stdout), result.stderr)

    def test_thresholds_use_semantics_and_errors_cannot_silently_skip_guards(self):
        shell = SHELLS[1]
        for left, right, expected in (("239.1", "240", "false"), ("240.1", "240", "true"),
                                      ("999.11", "1000", "false"), ("3000000000.1", "289", "true")):
            result = self.invoke(shell, ["at-least", left, right])
            self.assertEqual((0, expected + "\n"), (result.returncode, result.stdout), result.stderr)
        result = self.invoke(shell, ["999.0", "240"], suffix='if flyway_at_least "$1" "$2"; then echo yes; else echo no; fi\n')
        self.assertEqual(91, result.returncode)
        self.assertEqual("", result.stdout)


# The read-only mould audit is an operator tool reviewed in the repository
# checkout. LegacyBootstrapCoordinatorPostgresTest re-runs this module inside a
# staged /bootstrap tree that only carries the declared bootstrap inputs
# (migrate.sh, export_legacy.ps1, *.py, *.sql, mapping and crosswalk), so the
# script is absent there by design. A repository checkout (which has .github)
# always runs the check, so a missing or renamed script still fails loudly.
AUDIT_SCRIPT = ROOT / "server/legacy_migration/audit_mould_manufacturers.ps1"
IN_REPOSITORY_CHECKOUT = (ROOT / ".github").is_dir()


@unittest.skipUnless(IN_REPOSITORY_CHECKOUT,
                     "operator audit script is outside the staged legacy bootstrap input set")
class ReadOnlyAuditHeadTests(unittest.TestCase):
    def test_mould_audit_reports_the_semantic_head_not_the_last_applied_row(self):
        # A dotted backfill can be the row applied last; the reported migration is the
        # head under the reviewed history ordering, never ORDER BY installed_rank DESC.
        script = AUDIT_SCRIPT.read_text(encoding="utf-8")
        ordering = "ORDER BY string_to_array(version, '.')::numeric[]"
        self.assertIn(ordering, verify_candidate.history_rows_sql())
        self.assertNotIn("installed_rank DESC", script)
        self.assertIn("'latestMigration',(SELECT version FROM flyway_schema_history WHERE success AND "
                      "version IS NOT NULL " + ordering + " DESC LIMIT 1)", script)


if __name__ == "__main__":
    unittest.main()
