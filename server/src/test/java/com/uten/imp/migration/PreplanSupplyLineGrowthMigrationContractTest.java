package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V640 未订货的申请明细就地追加(ADR-099 数量单一入口)的迁移契约。
 *
 * <p>不能回退的口径：① 只新增两个判定函数, 不加表、不加列、不动触发器; ② 三个身份守卫
 * 只在「明细仍未订货」时放开只增不减的改量, 且都走 pg_get_functiondef 锚点补丁(锚点不中
 * 宁可失败); ③ 「未订货」= 申请开着、明细未删、已订量 0、无任何订货单来源引用(含待财务
 * 审核的草稿订货单)。
 */
class PreplanSupplyLineGrowthMigrationContractTest {

    private static final String MIGRATION =
            "db/migration/V640__preplan_supply_line_growth_in_place.sql";

    @Test
    void v640OnlyAddsThreePredicateFunctionsAndTouchesNoTableOrTrigger() throws IOException {
        String sql = resource(MIGRATION);
        assertThat(sql)
                .contains("CREATE OR REPLACE FUNCTION fn_preplan_external_item_unordered(p_route TEXT, p_item UUID)")
                .contains("CREATE OR REPLACE FUNCTION fn_preplan_supply_action_growable(p_action UUID)")
                .contains("CREATE OR REPLACE FUNCTION fn_is_preplan_supply_line_growth(p_table TEXT, p_old JSONB, p_new JSONB)")
                .contains("COMMENT ON FUNCTION fn_preplan_external_item_unordered(TEXT, UUID) IS")
                .contains("COMMENT ON FUNCTION fn_preplan_supply_action_growable(UUID) IS")
                .contains("COMMENT ON FUNCTION fn_is_preplan_supply_line_growth(TEXT, JSONB, JSONB) IS");
        String upper = sql.toUpperCase(java.util.Locale.ROOT);
        assertThat(upper)
                .doesNotContain("CREATE TABLE")
                .doesNotContain("ALTER TABLE")
                .doesNotContain("CREATE TRIGGER")
                .doesNotContain("DROP TRIGGER")
                .doesNotContain("DROP FUNCTION")
                .doesNotContain("UPDATE PREPLAN_SUPPLY_ACTIONS")
                .doesNotContain("UPDATE PREPLAN_SUPPLY_ACTION_ALLOCATIONS");
    }

    @Test
    void v640UnorderedMeansOpenRequestZeroOrderedAndNoOrderSourceEvenDraft() throws IOException {
        String sql = resource(MIGRATION);
        assertThat(sql)
                .contains("request.status IN (0, 1)")
                .contains("request.is_closed = FALSE")
                .contains("COALESCE(request.is_stopped, FALSE) = FALSE")
                .contains("COALESCE(item.ordered_qty, 0) = 0")
                .contains("FROM purchase_order_item_sources source")
                .contains("WHERE source.request_item_id = item.id")
                .contains("application.status IN (0, 1)")
                .contains("application.is_closed = FALSE")
                .contains("FROM subcontract_order_item_sources source")
                .contains("WHERE source.application_item_id = item.id")
                .doesNotContain("header.status");
    }

    @Test
    void v640GrowableRequiresExternalizedCreatedSupplyWithoutTransfersOrClaims() throws IOException {
        String sql = resource(MIGRATION);
        assertThat(sql)
                .contains("action.operation_type = 'SUPPLY'")
                .contains("action.status = 'CREATED'")
                .contains("action.route IN ('BUY', 'SUBCONTRACT')")
                .contains("action.external_document_type IN ('PURCHASE_REQUEST', 'SUBCONTRACT_APPLICATION')")
                .contains("NOT fn_preplan_action_has_future_transfer(action.id)")
                .contains("NOT fn_preplan_action_has_shared_claims(action.id)")
                .contains("NOT fn_preplan_external_item_unordered(action.route, allocation.external_item_id)")
                .contains("OR fn_preplan_external_item_unordered(action.route, action.public_surplus_external_item_id)");
    }

    @Test
    void v640RequestLineGrowthMeansQtyOnlyIncreaseAnchoredByAGrowableAction() throws IOException {
        String sql = resource(MIGRATION);
        assertThat(sql)
                .contains("p_table IN ('purchase_request_items', 'subcontract_application_items')")
                .contains("(p_old - ARRAY['qty', 'updated_at', 'updated_by'])")
                .contains("(p_new->>'qty')::numeric > (p_old->>'qty')::numeric")
                .contains("OR action.public_surplus_external_item_id = (p_old->>'id')::uuid)")
                .contains("OR fn_is_preplan_supply_line_growth(TG_TABLE_NAME,to_jsonb(OLD),to_jsonb(NEW))) THEN RETURN NEW; END IF;");
    }

    @Test
    void v640PatchesTheFourGuardsByAnchorAndOnlyAllowsIncreases() throws IOException {
        String sql = resource(MIGRATION);
        for (String guard : new String[]{
                "fn_guard_production_supply_source_item()",
                "fn_guard_preplan_supply_action_history()",
                "fn_guard_preplan_supply_allocation_history()",
                "fn_guard_preplan_public_surplus_history()"}) {
            assertThat(sql).contains("pg_get_functiondef('" + guard + "'::regprocedure)");
        }
        assertThat(sql)
                .contains("NEW.requested_qty > OLD.requested_qty")
                .contains("NEW.allocated_qty > OLD.allocated_qty")
                .contains("NEW.public_surplus_qty > OLD.public_surplus_qty")
                .contains("fn_preplan_supply_action_growable(OLD.id)")
                .contains("fn_preplan_supply_action_growable(OLD.action_id)")
                .contains("replace(definition, E'\\r\\n', E'\\n')")
                .contains("<> 1 THEN")
                .contains("USING ERRCODE = '23514'");
        assertThat(countOccurrences(sql, "DO $patch$")).isEqualTo(4);
        assertThat(countOccurrences(sql, "EXECUTE patched;")).isEqualTo(4);
    }

    @Test
    void v640UsesOnlyAsciiParenthesesInNewText() throws IOException {
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
        try (var in = PreplanSupplyLineGrowthMigrationContractTest.class
                .getClassLoader().getResourceAsStream(path)) {
            assertThat(in).as(path).isNotNull();
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
    }
}
