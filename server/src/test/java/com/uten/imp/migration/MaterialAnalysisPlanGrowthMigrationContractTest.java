package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V645 追加自制并入未开工的生产计划(ADR-104)的迁移契约。
 *
 * <p>不能回退的口径：① 只新增四个判定函数 + 一条对账触发器, 不加表、不加列, 不 DROP 任何触发器;
 * ② 三个身份守卫只在「计划仍未开工」时放开只增不减的改量, 且都走 pg_get_functiondef 锚点补丁
 * (锚点不中宁可失败); ③ 「未开工」= 草稿或已审核、未删除/未取消/未中止/未结案、恰一条明细且
 * 完工/入库/封顶累计全 0、没有报工/拆批、每段仍 WAITING/READY、备料单仍是未审核未发料未删除的草稿;
 * ④ 执行段本身不改量——追加量在同一个 CONFIRMED 计划包里另起一段。
 */
class MaterialAnalysisPlanGrowthMigrationContractTest {

    private static final String MIGRATION =
            "db/migration/V645__material_analysis_plan_growth_in_place.sql";

    @Test
    void v645OnlyAddsPredicateFunctionsAndOneDeferredCheckTouchingNoTable() throws IOException {
        String sql = resource(MIGRATION);
        assertThat(sql)
                .contains("CREATE OR REPLACE FUNCTION fn_material_analysis_plan_growable(p_plan UUID)")
                .contains("CREATE OR REPLACE FUNCTION fn_is_material_analysis_plan_item_growth(")
                .contains("CREATE OR REPLACE FUNCTION fn_is_material_analysis_plan_link_growth(")
                .contains("CREATE OR REPLACE FUNCTION fn_is_material_analysis_plan_item_supply_growth(p_table TEXT, p_old JSONB, p_new JSONB)")
                .contains("CREATE OR REPLACE FUNCTION fn_check_material_analysis_plan_item_link_qty()")
                .contains("CREATE CONSTRAINT TRIGGER trg_check_material_analysis_plan_item_link_qty")
                .contains("AFTER UPDATE OF qty ON production_plan_items")
                .contains("DEFERRABLE INITIALLY DEFERRED")
                .contains("WHEN (OLD.qty IS DISTINCT FROM NEW.qty)")
                .contains("COMMENT ON FUNCTION fn_material_analysis_plan_growable(UUID) IS");
        String upper = sql.toUpperCase(java.util.Locale.ROOT);
        assertThat(upper)
                .doesNotContain("CREATE TABLE")
                .doesNotContain("ALTER TABLE")
                .doesNotContain("DROP TRIGGER")
                .doesNotContain("DROP FUNCTION")
                .doesNotContain("UPDATE PRODUCTION_PLAN_ITEMS")
                .doesNotContain("UPDATE PRODUCTION_MATERIAL_ANALYSIS_PLAN_LINKS")
                .doesNotContain("UPDATE PRODUCTION_EXECUTION_SEGMENTS");
    }

    @Test
    void v645NotStartedMeansOpenPlanUntouchedSegmentsNoReportNoSplitAndDraftDrawsOnly() throws IOException {
        String sql = resource(MIGRATION);
        assertThat(sql)
                .contains("plan.material_analysis_id IS NOT NULL")
                .contains("plan.is_deleted = FALSE")
                .contains("COALESCE(plan.is_canceled, FALSE) = FALSE")
                .contains("COALESCE(plan.is_stopped, FALSE) = FALSE")
                .contains("COALESCE(plan.is_closed, FALSE) = FALSE")
                .contains("plan.status IN (0, 1)")
                .contains("WHERE item.plan_id = plan.id AND item.is_deleted = FALSE) = 1")
                .contains("OR COALESCE(item.fqty, 0) <> 0")
                .contains("OR COALESCE(item.capped_qty, 0) <> 0")
                .contains("AND segment.status NOT IN ('WAITING', 'READY')")
                .contains("JOIN production_execution_segment_splits split")
                .contains("JOIN production_daily_report_items report")
                .contains("AND document.document_type = 'DRAW'")
                .contains("OR draw.status <> 0")
                .contains("AND COALESCE(item.issued_qty, 0) > 0")
                .contains("AND package.execution_model_version = 1) = 1)");
    }

    @Test
    void v645GrowthPredicatesOnlyAllowIncreasesWithTheLinkAndItemInStep() throws IOException {
        String sql = resource(MIGRATION);
        assertThat(sql)
                .contains("AND p_after > p_before")
                .contains("AND COALESCE(p_old_cap, 0) = COALESCE(p_new_cap, 0)")
                .contains("SELECT p_old_status = p_new_status")
                .contains("AND p_new_status IN ('SUBMITTED', 'APPROVED')")
                .contains("AND COALESCE(p_new_submitted, 0) >= COALESCE(p_old_submitted, 0)")
                .contains("AND COALESCE(p_new_surplus, 0) >= COALESCE(p_old_surplus, 0)")
                .contains("AND item.qty = COALESCE(p_new_submitted, 0) + COALESCE(p_new_surplus, 0))")
                .contains("(p_old - ARRAY['qty', 'updated_at', 'updated_by'])")
                .contains("AND (p_new->>'qty')::numeric > (p_old->>'qty')::numeric")
                .contains("= COALESCE(NEW.qty, 0) + COALESCE(NEW.capped_qty, 0)");
    }

    @Test
    void v645PatchesTheThreeGuardsByAnchorAndKeepsTheirOriginalRefusals() throws IOException {
        String sql = resource(MIGRATION);
        for (String guard : new String[]{
                "fn_guard_material_analysis_plan_item_identity()",
                "fn_sync_material_analysis_plan_link_qty()",
                "fn_guard_production_supply_source_item()"}) {
            assertThat(sql).contains("pg_get_functiondef('" + guard + "'::regprocedure)");
        }
        assertThat(sql)
                .contains("AND NOT fn_is_daily_report_plan_target_change(OLD.id,OLD.qty,NEW.qty,OLD.capped_qty,NEW.capped_qty) AND NOT fn_is_material_analysis_plan_item_growth(OLD.id,OLD.qty,NEW.qty,OLD.capped_qty,NEW.capped_qty))")
                .contains("AND NOT fn_is_material_analysis_plan_link_growth(OLD.plan_id, OLD.allocation_status, NEW.allocation_status,")
                .contains("OR fn_is_material_analysis_plan_item_supply_growth(TG_TABLE_NAME,to_jsonb(OLD),to_jsonb(NEW))) THEN RETURN NEW; END IF;")
                .contains("replace(definition, E'\\r\\n', E'\\n')")
                .contains("<> 1 THEN")
                .contains("USING ERRCODE = '23514'");
        assertThat(countOccurrences(sql, "DO $patch$")).isEqualTo(3);
        assertThat(countOccurrences(sql, "EXECUTE patched;")).isEqualTo(3);
    }

    @Test
    void v645UsesOnlyAsciiParenthesesInNewText() throws IOException {
        String sql = resource(MIGRATION);
        assertThat(sql).doesNotContain("（").doesNotContain("）");
    }

    private static int countOccurrences(String text, String needle) {
        int count = 0;
        for (int index = text.indexOf(needle); index >= 0; index = text.indexOf(needle, index + needle.length())) {
            count++;
        }
        return count;
    }

    private static String resource(String path) throws IOException {
        try (var in = MaterialAnalysisPlanGrowthMigrationContractTest.class
                .getClassLoader().getResourceAsStream(path)) {
            assertThat(in).as(path).isNotNull();
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
    }
}
