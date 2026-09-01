package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class MeasurementWeightLedgerMigrationContractTest {

    @Test
    void v435AddsNullableActualWeightWithoutGuessingHistoricalValues()
            throws Exception {
        String sql = source().toLowerCase();

        assertThat(sql)
                .contains("alter table stock_movements")
                .contains("add column weight numeric(18,4)")
                .contains("stock_movements_weight_non_negative_chk")
                .contains("weight is null or weight >= 0")
                .contains("alter table procurement_inspection_items")
                .contains("add column received_weight numeric(18,4)")
                .contains("procurement_inspection_received_weight_non_negative_chk")
                .contains("received_weight is null or received_weight >= 0")
                .doesNotContain("update stock_movements")
                .doesNotContain("update procurement_inspection_items")
                .contains("never inferred from goods.m_weight")
                .doesNotContain("select m_weight")
                .doesNotContain("g.m_weight");
    }

    @Test
    void reconciliationViewRefusesToPresentIncompleteHistoryAsDrift()
            throws Exception {
        String sql = source().toLowerCase();

        assertThat(sql)
                .contains("create or replace view v_stock_weight_reconciliation")
                .contains("count(weight) as weighted_movement_count")
                .contains("sum(weight * direction)")
                .contains("incomplete_movement_weight")
                .contains("balance_weight_unknown")
                .contains("then balance.weight - movement.movement_weight")
                .contains("else null")
                .doesNotContain("coalesce(balance.weight, 0)");
    }

    private static String source() throws Exception {
        Path direct = Path.of(
                "src/main/resources/db/migration/V435__measurement_weight_ledger.sql");
        Path path = Files.exists(direct)
                ? direct : Path.of("server").resolve(direct);
        return Files.readString(path, StandardCharsets.UTF_8);
    }
}
