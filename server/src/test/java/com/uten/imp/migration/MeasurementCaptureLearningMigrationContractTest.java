package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class MeasurementCaptureLearningMigrationContractTest {

    @Test
    void v442SeparatesProfilesEvidenceDecisionsAndExplicitWeightUnits()
            throws Exception {
        String sql = compact(read(
                "src/main/resources/db/migration/"
                        + "V442__measurement_capture_learning.sql"));

        assertThat(sql)
                .contains("create table unit_measurement_profiles")
                .contains("create table measurement_capture_profiles")
                .contains("unique (goods_id, operation_family)")
                .contains("create table measurement_capture_line_snapshots")
                .contains("create table measurement_capture_evidence")
                .contains("create table measurement_capture_decision_events")
                .contains("create table legacy_measurement_source_registry")
                .contains("create table legacy_measurement_profile_snapshots")
                .contains("create table legacy_measurement_exceptions")
                .contains("business_quantity_and_actual_weight")
                .contains("actual_weight_unit_id")
                .contains("received_weight_unit_id")
                .contains("is append-only")
                .contains("expected_version")
                .contains("resulting_version = expected_version + 1")
                .doesNotContain("'weight_only'")
                .doesNotContain("select m_weight")
                .doesNotContain("lower(units.name)")
                .doesNotContain("lower(unit.name)");
    }

    @Test
    void legacyInferenceRequiresBoundAuthorityAndNeverConfirmsUnitlessWeight()
            throws Exception {
        String sql = compact(read(
                "legacy_migration/migrate_measurement_profiles.sql"));

        assertThat(sql)
                .contains("migration_mode = 'bootstrap'")
                .contains("export_manifest_sha256 is not null")
                .contains("source_backup_sha256 is not null")
                .contains("export_approval_reference is not null")
                .contains("positive_weight_document_count >= 3")
                .contains("positive_weight_day_count >= 2")
                .contains("'provisional'")
                .contains("actual_weight_unit_id")
                .contains("null,")
                .contains("weight_without_quantity")
                .contains("source_capability_drift")
                .doesNotContain("'confirmed'")
                .doesNotContain("'weight_only'")
                .doesNotContain("select goods.m_weight")
                .doesNotContain("units.name");
    }

    @Test
    void legacyQuantityAndBalanceResolversAreFailClosed()
            throws Exception {
        String subcontract = compact(read(
                "legacy_migration/migrate_subcontract.sql"));
        assertThat(subcontract)
                .contains("coalesce(nullif(s.stqty, 0), s.qty)")
                .contains("s.stqty > 0")
                .contains("s.qty > 0")
                .contains("s.stqty <> s.qty")
                .contains("23514");

        String stock = compact(read(
                "legacy_migration/migrate_stock_docs.sql"));
        assertThat(stock)
                .contains("create temp table latest_stock_balance_stage")
                .contains("sum(coalesce(g.fact_qty, g.qty))")
                .contains("sum(coalesce(g.fact_weight, g.weight))")
                .contains("'weight_without_quantity'")
                .contains("'negative_weight'")
                .contains("'quantity_weight_sign_conflict'")
                .contains("'fact_null_fallback'")
                .contains("when fact_weight = 0")
                .contains("then null")
                .contains("from latest_stock_balance_stage")
                .doesNotContain("sum(g.qty) as fact_qty")
                .doesNotContain("sum(g.weight) as fact_weight");
    }

    @Test
    void unitGovernanceUsesReviewedLegacyIdsNotNames()
            throws Exception {
        String sql = compact(read("legacy_migration/migrate_unit.sql"));

        assertThat(sql)
                .contains("insert into unit_measurement_profiles")
                .contains("(108, 1.000000000000::numeric)")
                .contains("(109, 0.001000000000::numeric)")
                .contains("(241, 0.500000000000::numeric)")
                .contains("source_unit.legacy_id = mapping.legacy_id")
                .contains("join units kg on kg.legacy_id = 108")
                .doesNotContain("where lower(source_unit.name)")
                .doesNotContain("like '%kg%'");
    }

    @Test
    void profilerIsAggregateOnlyAndCanRequireAuthoritativeExport()
            throws Exception {
        String python = compact(read(
                "legacy_migration/profile_measurement_evidence.py"));
        String shell = compact(read("legacy_migration/migrate.sh"));

        assertThat(python)
                .contains("aggregate_only_no_business_identifiers")
                .contains("--require-authoritative")
                .contains("format3_manifest_or_checksum_missing")
                .contains("manifest_file_digest_drift")
                .contains("status !=")
                .contains("legacy_dual_pattern_3_docs_2_days");
        assertThat(shell)
                .contains("--measurement-profiles")
                .contains("migrate_measurement_profiles")
                .contains("source_backup_sha256")
                .contains("export_approval_reference");
    }

    private static String read(String relative) throws Exception {
        Path direct = Path.of(relative);
        Path path = Files.exists(direct)
                ? direct : Path.of("server").resolve(relative);
        return Files.readString(path, StandardCharsets.UTF_8);
    }

    private static String compact(String value) {
        return value.toLowerCase(Locale.ROOT)
                .replaceAll("\s+", " ")
                .trim();
    }
}
