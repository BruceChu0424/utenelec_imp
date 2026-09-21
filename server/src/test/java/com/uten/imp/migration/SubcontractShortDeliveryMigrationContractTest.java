package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V636 委外允许损耗与回厂短交案件(ADR-098)的迁移契约。
 *
 * <p>不能回退的口径：① 允许损耗是两列(货品主档记忆 + 订货明细冻结值), 0 到 100, 空 = 未设;
 * ② 案件表一行明细同一时刻最多一个开放案件(部分唯一索引), 状态/判定/结案字段成对约束,
 * 事件表追加式; ③ 两张新表自带可评审的行级审计触发器; ④ 独立权限点 subcontract_short_delivery:decide
 * 默认授予持 submit_finance 的部门; ⑤ 供应商汇总视图只算已结清的订货行, 接受损耗行按改量前原量。
 */
class SubcontractShortDeliveryMigrationContractTest {

    private static final String MIGRATION =
            "db/migration/V636__subcontract_loss_tolerance_and_short_delivery_cases.sql";

    @Test
    void v636AddsAllowedLossColumnsOnGoodsAndOrderItemsAsPercentages() throws IOException {
        String sql = resource(MIGRATION);
        assertThat(sql)
                .contains("ALTER TABLE goods")
                .contains("ADD COLUMN subcontract_allowed_loss_pct NUMERIC(5,2)")
                .contains("ALTER TABLE subcontract_order_items")
                .contains("ADD COLUMN allowed_loss_pct NUMERIC(5,2)")
                .contains("allowed_loss_pct >= 0 AND allowed_loss_pct <= 100")
                .contains("COMMENT ON COLUMN goods.subcontract_allowed_loss_pct IS")
                .contains("COMMENT ON COLUMN subcontract_order_items.allowed_loss_pct IS")
                .doesNotContain("UPDATE subcontract_order_items")
                .doesNotContain("UPDATE goods");
    }

    @Test
    void v636CaseTableKeepsOneOpenCasePerOrderLineWithPairedStateConstraints() throws IOException {
        String sql = resource(MIGRATION);
        assertThat(sql)
                .contains("CREATE TABLE subcontract_short_delivery_cases")
                .contains("'SEVERE', 'BELOW_FLOOR', 'WITHIN_TOLERANCE', 'UNSET_TOLERANCE'")
                .contains("'PENDING_OWNER', 'WAITING_MORE', 'ACCEPTED_LOSS', 'COMPLETED', 'CANCELED'")
                .contains("decision                  TEXT CHECK (decision IN ('WAIT_MORE', 'ACCEPT_LOSS'))")
                .contains("CREATE UNIQUE INDEX uq_subcontract_short_delivery_open_item")
                .contains("WHERE status IN ('PENDING_OWNER', 'WAITING_MORE')")
                .contains("CHECK ((decision IS NULL) = (decided_at IS NULL))")
                .contains("CHECK (decision IS DISTINCT FROM 'WAIT_MORE' OR expected_complete_by IS NOT NULL)")
                .contains("CHECK (status <> 'ACCEPTED_LOSS' OR (decision = 'ACCEPT_LOSS'")
                .contains("CHECK (status NOT IN ('PENDING_OWNER', 'WAITING_MORE') OR closed_at IS NULL)")
                .contains("waste_id                  UUID REFERENCES subcontract_wastes(id)")
                .contains("CREATE TABLE subcontract_short_delivery_case_events")
                .contains("Subcontract short delivery case events are append-only");
    }

    @Test
    void v636NewTablesOwnExplicitRowLevelAuditTriggers() throws IOException {
        String sql = resource(MIGRATION).replaceAll("\\s+", " ").toLowerCase(java.util.Locale.ROOT);
        for (String table : new String[]{
                "subcontract_short_delivery_cases", "subcontract_short_delivery_case_events"}) {
            assertThat(sql)
                    .contains("create trigger trg_audit_" + table)
                    .contains("after insert or update or delete on " + table)
                    .contains("enable always trigger trg_audit_" + table);
        }
        assertThat(sql).contains("for each row execute function fn_audit()");
    }

    @Test
    void v636GrantsTheDecidePermissionToSubmitFinanceDepartmentsOnly() throws IOException {
        String sql = resource(MIGRATION);
        assertThat(sql)
                .contains("('subcontract_short_delivery:decide',")
                .contains("'委外回厂短交判定', '委外管理', '委外订货', 331,")
                .contains("('subcontract.order', 'subcontract_short_delivery:decide')")
                .contains("holder.code = 'subcontract_order:submit_finance'")
                .contains("target.code = 'subcontract_short_delivery:decide'")
                .contains("ON CONFLICT DO NOTHING");
    }

    @Test
    void v636SupplierLossViewsCountOnlySettledLinesAndUseOriginalOrderedQty() throws IOException {
        String sql = resource(MIGRATION);
        assertThat(sql)
                .contains("CREATE OR REPLACE VIEW v_subcontract_supplier_goods_loss_summary")
                .contains("CREATE OR REPLACE VIEW v_subcontract_supplier_loss_summary")
                .contains("COALESCE(accepted.ordered_qty, order_item.qty) AS ordered_qty")
                .contains("COALESCE(accepted.loss_qty, 0) AS loss_qty")
                .contains("WHERE c.order_item_id = order_item.id AND c.status = 'ACCEPTED_LOSS'")
                .contains("OR COALESCE(order_item.received_qty, 0) - COALESCE(order_item.returned_qty, 0)")
                .contains("ROUND(SUM(loss_qty) * 100 / SUM(ordered_qty), 2)");
    }

    @Test
    void v636UsesOnlyAsciiParenthesesInNewText() throws IOException {
        String sql = resource(MIGRATION);
        assertThat(sql).doesNotContain("（").doesNotContain("）");
    }

    private static String resource(String path) throws IOException {
        try (var in = SubcontractShortDeliveryMigrationContractTest.class
                .getClassLoader().getResourceAsStream(path)) {
            assertThat(in).as(path).isNotNull();
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
    }
}
