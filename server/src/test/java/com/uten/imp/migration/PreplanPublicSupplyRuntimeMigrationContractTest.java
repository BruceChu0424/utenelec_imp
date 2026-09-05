package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class PreplanPublicSupplyRuntimeMigrationContractTest {

    private static String migration() throws Exception {
        Path direct = Path.of("src", "main", "resources", "db", "migration",
                "V474__preplan_public_supply_and_inbound_allocation.sql");
        Path fallback = Path.of("server").resolve(direct);
        return Files.readString(Files.exists(direct) ? direct : fallback,
                StandardCharsets.UTF_8);
    }

    @Test
    void addsAppendOnlyRuntimeSurplusAndAllAnchorCapacity() throws Exception {
        assertThat(migration())
                .contains("CREATE TABLE preplan_public_supply_events")
                .contains("events are append-only")
                .contains("fn_preplan_direct_overorder_capacity")
                .contains("public_surplus_external_item_id")
                .contains("safety_external_item_id")
                .contains("fn_preplan_order_public_source_qty")
                .contains("fn_preplan_order_exact_attributed_qty")
                .contains("SHARED_FUTURE_CLAIM")
                .contains("fn_preplan_public_source_open_qty");
    }

    @Test
    void guardsWarehouseIdentityAndPreservesHistoricalAudit() throws Exception {
        assertThat(migration())
                .contains("v_preplan_exact_peg_warehouse_mismatches")
                .contains("preplan_exact_peg_main_warehouse_guard")
                .contains("preplan_exact_analysis_warehouse_immutable_guard")
                .contains("preplan_exact_action_warehouse_immutable_guard")
                .contains("preplan_exact_reservation_warehouse_immutable_guard")
                .doesNotContain("UPDATE preplan_analysis_stock_exact_pegs SET");
    }

    @Test
    void resetAndClaimGuardsAreForwardOnlyAndNoStringForeignKeyParsing()
            throws Exception {
        assertThat(migration())
                .contains("preplan_public_supply_events'', ''CLEAR")
                // business_data_reset() 的失败关闭靠 unknown_tables/重复分类拒绝，
                // 没有按表数量的硬编码计数守卫；扩展只机械插入 CLEAR 策略行。
                .contains("other_claim_open+current_claim_open")
                .contains("fn_preplan_public_source_open_qty")
                .doesNotContain("idempotency_key LIKE")
                .doesNotContain("clear_count - v454_celebration_table_count")
                .doesNotContain("ALTER TABLE preplan_supply_actions DROP COLUMN");
    }
}
