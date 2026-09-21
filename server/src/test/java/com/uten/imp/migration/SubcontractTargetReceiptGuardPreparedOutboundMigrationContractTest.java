package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V638 静态契约：委外前置自制订货超量后同一明细混合出仓(PREPARED + DIRECT), 回厂守卫
 * fn_assert_subcontract_target_outbound_receipt 的「已审出仓量 / 已消费量」合计必须计入
 * PREPARED_OUTBOUND 行; 激活条件(明细含 DIRECT/MAKE_THEN/COMPONENT 行)原样保留。
 */
class SubcontractTargetReceiptGuardPreparedOutboundMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V638__subcontract_target_receipt_guard_counts_prepared_outbound.sql");

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
    void issuedAndConsumedSumsCountPreparedOutboundThroughAnchoredPatch() throws Exception {
        String sql = compact(MIGRATION);

        assertThat(sql)
                .contains("pg_get_functiondef( 'fn_assert_subcontract_target_outbound_receipt(uuid)'::regprocedure)")
                .contains("replace(pg_get_functiondef(")
                .contains("e'\\r\\n', e'\\n'")
                .contains("join subcontract_material_plan_items plan_item on plan_item.id=item.plan_item_id")
                .contains("''direct_outbound'',''make_then_outbound'',''component_outbound'')")
                .contains("''direct_outbound'',''make_then_outbound'',''component_outbound'',''prepared_outbound'')")
                .contains("already counts prepared_outbound, nothing to do")
                .contains("if hits <> 1 then raise exception")
                .contains("activation condition must stay untouched")
                .contains("patched := replace(definition, anchor, replacement)")
                .contains("execute patched")
                .contains("comment on function fn_assert_subcontract_target_outbound_receipt(uuid)");
        // 锚点补丁只替换合计 JOIN 一处(替换文本只在变量里出现一次); 激活条件另作独立形状断言;
        // 已是补丁后形状时 NOTICE 跳过, 未知形状 23514 失败。
        assertThat(occurrences(sql, "raise exception")).isEqualTo(3);
        assertThat(occurrences(sql, "raise notice")).isEqualTo(1);
        assertThat(occurrences(sql, "''prepared_outbound''")).isEqualTo(1);
    }

    @Test
    void onlyOneFunctionBodyIsPatchedAndNothingElseChanges() throws Exception {
        String sql = compact(MIGRATION);

        assertThat(sql)
                .doesNotContain("create table")
                .doesNotContain("alter table")
                .doesNotContain("drop trigger")
                .doesNotContain("create trigger")
                .doesNotContain("create constraint trigger")
                .doesNotContain("drop function")
                .doesNotContain("create or replace function")
                .doesNotContain("update subcontract_material_plan_items")
                .doesNotContain("update subcontract_material_issue_items");
        assertThat(occurrences(sql, "execute patched")).isEqualTo(1);
    }

    @Test
    void draftOrderLineAmountsAreNormalizedOnlyForDrafts() throws Exception {
        String sql = compact(MIGRATION);

        // 草稿(status = 0)且金额 <> 数量×单价(×表头汇率)的采购/委外订货行归一, 表头合计按未删明细重算;
        // 已审/红冲/取消单不碰(每条 UPDATE 都带 status = 0)。
        assertThat(sql)
                .contains("update purchase_order_items oi set amount_original = oi.qty * oi.price")
                .contains("update subcontract_order_items oi set amount_original = oi.qty * oi.price")
                .contains("amount_local = oi.qty * oi.price * coalesce(po.exchange_rate, 1)")
                .contains("amount_local = oi.qty * oi.price * coalesce(so.exchange_rate, 1)")
                .contains("update purchase_orders po set total_original = totals.original, total_local = totals.local")
                .contains("update subcontract_orders so set total_original = totals.original, total_local = totals.local")
                .contains("oi.price is not null and oi.qty is not null");
        assertThat(occurrences(sql, "update ")).isEqualTo(4);
        assertThat(occurrences(sql, "po.status = 0")).isEqualTo(2);
        assertThat(occurrences(sql, "so.status = 0")).isEqualTo(2);
        assertThat(sql)
                .doesNotContain("delete from")
                .doesNotContain("status = 1")
                .doesNotContain("status = -1");
    }
}
