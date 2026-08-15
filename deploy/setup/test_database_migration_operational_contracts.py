import pathlib
import unittest


SETUP_ROOT = pathlib.Path(__file__).resolve().parent


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
