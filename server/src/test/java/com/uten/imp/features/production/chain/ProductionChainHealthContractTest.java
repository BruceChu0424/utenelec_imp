package com.uten.imp.features.production.chain;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionChainHealthContractTest {

    @Test
    void salesGapDetailSqlFormatsTheSchedulingExpressionBeforeExecution() {
        String sql = ProductionChainHealthService.salesGapDetailSql(" FROM fixture");

        assertThat(sql)
                .doesNotContain("%s")
                .contains("GREATEST(")
                .contains("COALESCE(i.qty,0) - COALESCE(i.shipped_qty,0)")
                .contains(" FROM fixture")
                .endsWith("o.bill_date LIMIT :limit");
    }

    @Test
    void salesGapScanRespectsV294FinanceConfirmationGate() throws Exception {
        // V294：未财务确认的订单对计划部不可见，断链扫描不得把它报成「有销售缺口·无物料分析」。
        String source = Files.readString(
                Path.of("src/main/java/com/uten/imp/features/production/chain/"
                        + "ProductionChainHealthService.java"),
                StandardCharsets.UTF_8);

        assertThat(source).contains("AND o.finance_confirmed = TRUE");
    }

    @Test
    void noDrawHealthCheckIgnoresFinishedInboundAndZeroMaterialPlans()
            throws Exception {
        String source = Files.readString(
                Path.of("src/main/java/com/uten/imp/features/production/chain/"
                        + "ProductionChainHealthService.java"),
                StandardCharsets.UTF_8);

        assertThat(source)
                .contains("JOIN stock_documents draw")
                .contains("draw.doc_type = 'DRAW'")
                .contains("FROM production_execution_segments segment")
                .contains("segment.plan_id = p.id")
                .contains("segment.material_requirement_mode = 'DEMANDED'")
                .contains("'READY', 'DISPATCHED', 'IN_PROGRESS', 'COMPLETED'");
    }
}
