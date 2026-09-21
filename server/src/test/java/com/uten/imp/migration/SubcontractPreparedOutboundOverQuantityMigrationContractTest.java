package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V634 静态契约：委外前置自制按 V589 超量下达(台账 required_qty = 归需求量 + 公共备货产出)
 * 后，V458 的 PREPARED_OUTBOUND 谱系守卫改看台账 required_qty，不再拿分析 SUBCONTRACT_MAKE
 * 行的 requested_qty(只记归需求量)卡订货行；其余身份/批次校验与 MAKE_THEN_OUTBOUND 分支原样保留。
 */
class SubcontractPreparedOutboundOverQuantityMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V634__subcontract_prepared_outbound_over_quantity_guard.sql");
    private static final Path V458 = Path.of(
            "src/main/resources/db/migration/"
                    + "V458__subcontract_make_before_order.sql");

    private static String compact(Path path) throws Exception {
        return Files.readString(path, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }

    private static long occurrences(String sql, String needle) {
        long count = 0;
        int index = 0;
        while ((index = sql.indexOf(needle, index)) >= 0) {
            count++;
            index += needle.length();
        }
        return count;
    }

    @Test
    void preparedOutboundQuantityCapFollowsTheMakeTaskLedger() throws Exception {
        String sql = compact(MIGRATION);

        assertThat(sql)
                .contains("create or replace function "
                        + "fn_assert_subcontract_preparation_source_before_v535( "
                        + "p_plan_item_id uuid )")
                .contains("plan_item.flow_mode = 'prepared_outbound'")
                .contains("task.status = 'active'")
                .contains("task.required_qty >= plan_item.planned_qty")
                .contains("batch.notify_qty >= plan_item.planned_qty")
                .contains("analysis_item.source_type = 'subcontract_make'")
                .contains("analysis_item.goods_id = plan_item.goods_id")
                .contains("analysis_item.color_id is not distinct from plan_item.color_id")
                .contains("analysis_item.unit_id = plan_item.unit_id")
                .contains("subcontract_prepared_outbound_lineage_guard")
                .doesNotContain("analysis_item.requested_qty >= plan_item.planned_qty");
    }

    @Test
    void makeThenOutboundBranchAndTriggersAreUntouched() throws Exception {
        String sql = compact(MIGRATION);
        String v458 = compact(V458);

        // MAKE_THEN_OUTBOUND 分支逐字沿用 V458(直下单准备行仍要求 requested_qty = planned_qty)。
        assertThat(sql)
                .contains("plan_item.flow_mode = 'make_then_outbound'")
                .contains("analysis_item.source_type = 'subcontract_preparation'")
                .contains("analysis_item.requested_qty = plan_item.planned_qty")
                .contains("subcontract_preparation_analysis_lineage_guard");
        assertThat(v458)
                .contains("analysis_item.requested_qty = plan_item.planned_qty")
                .contains("analysis_item.requested_qty >= plan_item.planned_qty");
        // 只换函数体：不建表、不加列、不动触发器、不改 V535 包装函数、不改行。
        assertThat(sql)
                .doesNotContain("create table")
                .doesNotContain("alter table")
                .doesNotContain("drop trigger")
                .doesNotContain("create trigger")
                .doesNotContain("create constraint trigger")
                .doesNotContain("drop function")
                .doesNotContain("update subcontract_material_plan_items")
                .doesNotContain("fn_assert_subcontract_preparation_source(p_plan_item_id uuid)");
        assertThat(occurrences(sql, "create or replace function")).isEqualTo(1);
        assertThat(occurrences(sql, "raise exception")).isEqualTo(2);
    }
}
