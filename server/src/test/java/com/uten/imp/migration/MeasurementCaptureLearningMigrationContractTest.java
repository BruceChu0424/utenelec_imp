package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V442 采集偏好学习的历史事实与 V745(ADR-135)退役后仍然成立的部分。
 *
 * <p>V442 字节冻结(已应用迁移不可改)；它建的七张采集/旧库计量表、解析视图与只追加拒绝函数已由 V745 删除，
 * 单重改由仓库称重自学习(goods_weight_*)。留下来的只有单位计量档案 unit_measurement_profiles
 * (V745 起用 mass_unit_code 标注质量单位)和老库导入的受审单位主键映射。
 */
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
    void legacyQuantityAndBalanceResolversAreFailClosedAndNeverImportUnitlessWeight()
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
                .contains("from latest_stock_balance_stage latest")
                // 老库重量单位不可证明：明细重量与余额重量都不导入，只有质量单位货品按数量精确换算。
                .contains("null::numeric, -- 老库明细重量单位不可证明")
                .contains("when latest.fact_qty > 0 and profile.mass_unit_code is not null")
                .contains("fn_weight_unit_kg_factor(profile.mass_unit_code)")
                .contains("left join unit_measurement_profiles profile on profile.unit_id = material.unit_id")
                .contains("delete from stock_weight_adjustments;")
                .doesNotContain("legacy_measurement_exceptions")
                .doesNotContain("sum(coalesce(g.fact_weight, g.weight))")
                .doesNotContain("s.amount, s.amount, s.weight")
                .doesNotContain("sum(g.qty) as fact_qty");
    }

    @Test
    void unitGovernanceUsesReviewedLegacyIdsForMassUnitCodesNotNames()
            throws Exception {
        String sql = compact(read("legacy_migration/migrate_unit.sql"));

        assertThat(sql)
                .contains("insert into unit_measurement_profiles")
                .contains("mass_unit_code")
                .contains("(108, 'kg')")
                .contains("(109, 'g')")
                .contains("(241, 'jin')")
                .contains("'legacy_explicit_id'")
                .contains("source_unit.legacy_id = mapping.legacy_id")
                .doesNotContain("canonical_unit_id")
                .doesNotContain("to_canonical_factor")
                .doesNotContain("where lower(source_unit.name)")
                .doesNotContain("like '%kg%'");
    }

    @Test
    void retiredMeasurementProfileStepIsGoneFromTheBootstrap()
            throws Exception {
        String shell = compact(read("legacy_migration/migrate.sh"));
        assertThat(shell)
                .doesNotContain("--measurement-profiles")
                .doesNotContain("migrate_measurement_profiles")
                .contains("source_backup_sha256")
                .contains("export_approval_reference");
        assertThat(exists("legacy_migration/migrate_measurement_profiles.sql")).isFalse();
        assertThat(exists("legacy_migration/profile_measurement_evidence.py")).isFalse();
    }

    private static boolean exists(String relative) {
        Path direct = Path.of(relative);
        return Files.exists(direct) || Files.exists(Path.of("server").resolve(relative));
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
