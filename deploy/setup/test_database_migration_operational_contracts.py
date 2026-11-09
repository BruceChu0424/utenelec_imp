import os
import pathlib
import shlex
import shutil
import subprocess
import sys
import unittest


SETUP_ROOT = pathlib.Path(__file__).resolve().parent
GUARD = SETUP_ROOT.parent / "updater" / "release_guard.py"
HISTORY_GATE_START = "echo '==> Validate Flyway history without mutating it'"
HISTORY_GATE_END = "echo '==> Compare restored Flyway rows with the independently trusted release manifest'"
# installed_rank order of a restored company-shaped history: 990.1 is backfilled after
# the larger integer 999, and the late backfill 999.13 is the row applied last.
BACKFILL_APPLIED_LAST = (
    "998\tV998__base.sql\t1\n999\tV999__whole.sql\t2\n990.1\tV990_1__backfill.sql\t3\n"
    "1000\tV1000__head.sql\t4\n999.13\tV999_13__late_backfill.sql\t5\n"
)
INTEGER_REGRESSION_LAST = "998\tV998__base.sql\t1\n1000\tV1000__head.sql\t2\n999\tV999__whole.sql\t3\n"


class DatabaseMigrationOperationalContractTest(unittest.TestCase):
    def test_role_hardener_uses_the_authenticated_manifest_as_inventory_authority(self) -> None:
        script = (SETUP_ROOT / "harden-existing-postgres-roles.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("expected_flyway_version=''", script)
        self.assertIn("verified-flyway-checksums", script)
        self.assertIn(
            'expected_migration_count="$trusted_manifest_count"', script
        )
        self.assertIn(
            "live Flyway versioned-row count differs from the authenticated release manifest",
            script,
        )
        self.assertIn(
            "live Flyway version/script/checksum rows differ from the authenticated release manifest",
            script,
        )
        self.assertNotIn("expected_flyway_version=255", script)
        self.assertNotIn("only fully enumerated V252", script)
        self.assertNotIn("V255 candidate must contain exactly 236", script)
        self.assertLess(
            script.index("verified-flyway-checksums"),
            script.index("install -d -m 0700 -o root -g root"),
        )

    def test_restore_drill_requires_explicit_signed_inventory_coordinates(self) -> None:
        script = (SETUP_ROOT / "drill-restore.sh").read_text(encoding="utf-8")

        self.assertIn("expected_flyway_version=''", script)
        self.assertIn("expected_migration_count=''", script)
        self.assertIn("--expected-flyway-version is required", script)
        self.assertIn("--expected-migration-count is required", script)
        self.assertIn("verified-flyway-checksums", script)
        self.assertIn(
            "restored Flyway versions/scripts/checksums differ from the signed production release manifest",
            script,
        )
        self.assertNotIn("expected_flyway_version=255", script)
        self.assertNotIn("expected_migration_count=236", script)
        self.assertLess(
            script.index("--expected-migration-count is required"),
            script.index("numeric_values=("),
        )

    @staticmethod
    def restore_drill_history_gate() -> str:
        script = (SETUP_ROOT / "drill-restore.sh").read_text(encoding="utf-8")
        return script[script.index(HISTORY_GATE_START):script.index(HISTORY_GATE_END)]

    @staticmethod
    def guard_history_summary(rows: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, "-I", str(GUARD), "flyway-rows", "--history", "--summary"],
            input=rows.encode("utf-8"), capture_output=True, check=False,
        )

    def test_restore_drill_head_is_the_shared_semantic_maximum_not_the_last_applied_row(self) -> None:
        script = (SETUP_ROOT / "drill-restore.sh").read_text(encoding="utf-8")
        gate = self.restore_drill_history_gate()
        self.assertNotIn("installed_rank DESC", script)
        read = gate.index("ORDER BY installed_rank;")
        summary = gate.index('flyway-rows --history --summary <<<"$ranked_history_rows"')
        compare = gate.index('[[ "$latest_flyway_version" == "$expected_flyway_version" ]]')
        self.assertLess(read, summary)
        self.assertLess(summary, compare)
        self.assertIn('read -r _ latest_flyway_version <<<"$ranked_history_summary"', gate)

    def test_restore_drill_guard_keeps_the_head_when_a_dotted_backfill_is_applied_last(self) -> None:
        result = self.guard_history_summary(BACKFILL_APPLIED_LAST)
        self.assertEqual(0, result.returncode, result.stderr.decode("utf-8", "replace"))
        self.assertEqual("5\t1000", result.stdout.decode("utf-8").strip())
        for rows in (
            INTEGER_REGRESSION_LAST,
            BACKFILL_APPLIED_LAST + "999.13\tV999_13__late_backfill.sql\t5\n",
            "999\tV999__whole.sql\t1\n999.1\tV999_2__forged.sql\t2\n",
        ):
            with self.subTest(rows=rows):
                result = self.guard_history_summary(rows)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual(b"", result.stdout)

    @unittest.skipIf(os.name == "nt" or shutil.which("bash") is None,
                     "the extracted drill gate runs under POSIX bash in the Linux tool job")
    def test_restore_drill_history_gate_accepts_a_backfill_applied_last_and_fails_closed(self) -> None:
        gate = self.restore_drill_history_gate().replace("/usr/bin/python3", shlex.quote(sys.executable))
        program = "\n".join((
            "set -Eeuo pipefail",
            "die() { printf 'DIE: %s\\n' \"$*\" >&2; exit 91; }",
            "psql_drill() {",
            "  case \"$2\" in",
            "    *to_regclass*) printf 't\\n' ;;",
            "    *'chr(9)'*) printf '%s' \"$RANKED_ROWS\" ;;",
            "    *'GROUP BY'*|*'IS DISTINCT FROM true'*|*'version IS NULL OR'*) printf '0\\n' ;;",
            "    *) printf '%s\\n' \"$ROW_COUNT\" ;;",
            "  esac",
            "}",
            gate,
            "printf 'HEAD=%s\\n' \"$latest_flyway_version\"",
        ))

        def run(rows: str, expected: str) -> subprocess.CompletedProcess:
            environment = {
                **os.environ, "RANKED_ROWS": rows, "ROW_COUNT": str(rows.count("\n")),
                "expected_flyway_version": expected, "expected_migration_count": str(rows.count("\n")),
                "trusted_release_guard": str(GUARD),
            }
            return subprocess.run(["bash", "-c", program], env=environment, text=True,
                                  capture_output=True, check=False)

        accepted = run(BACKFILL_APPLIED_LAST, "1000")
        self.assertEqual(0, accepted.returncode, accepted.stderr)
        self.assertIn("HEAD=1000\n", accepted.stdout)
        wrong_head = run(BACKFILL_APPLIED_LAST, "999")
        self.assertEqual(91, wrong_head.returncode)
        self.assertIn("latest Flyway version is 1000, expected 999", wrong_head.stderr)
        regression = run(INTEGER_REGRESSION_LAST, "1000")
        self.assertEqual(91, regression.returncode)
        self.assertIn("violates the shared rank-order", regression.stderr)
        self.assertNotIn("HEAD=", regression.stdout)

    def test_v289_runtime_and_restore_checks_cover_new_authority_tables(self) -> None:
        required_tokens = (
            "system_master_category_registry",
            "business_identifier_namespaces",
            "business_identifier_reservations",
            "business_identifier_conflicts",
            "client_default_settlement_migration_issues",
            "production_material_analysis_borrows",
            "trg_guard_production_material_analysis_borrow_mutation",
            "trg_set_updated_at_production_material_analysis_borrows",
            "trg_validate_pma_borrow_endpoint",
            "trg_audit_production_material_analysis_borrows",
        )
        for filename in (
            "harden-existing-postgres-roles.sh",
            "drill-restore.sh",
        ):
            with self.subTest(filename=filename):
                script = (SETUP_ROOT / filename).read_text(encoding="utf-8")
                for token in required_tokens:
                    self.assertIn(token, script)


if __name__ == "__main__":
    unittest.main()
