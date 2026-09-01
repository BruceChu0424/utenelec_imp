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

    @Test
    void healthScanUsesObjectScopesAndAuditsQuantityConservation()
            throws Exception {
        String source = Files.readString(
                Path.of("src/main/java/com/uten/imp/features/production/chain/"
                        + "ProductionChainHealthService.java"),
                StandardCharsets.UTF_8);

        assertThat(source)
                .contains("salesAccess.nativeReadScope")
                .contains("productionAccess.nativeReadScope")
                .contains("stockAccess.nativeReadScope")
                .contains("DUPLICATE_ACTIVE_DRAW_LINK")
                .contains("PLAN_QUANTITY_CACHE_MISMATCH")
                .contains("REPORT_OR_INBOUND_OVERFLOW")
                .contains("COMPLETED_SEGMENT_INVALID")
                .contains("FQC_QUANTITY_MISMATCH")
                .contains("FQC_RECOVERY_OR_CUTOVER_MISMATCH")
                .contains("COALESCE(item.iqty, 0) >")
                .contains("v_production_material_clearance")
                .contains("production_fqc_release_allocations")
                .contains("production_fqc_contribution_adjustments")
                .contains("production_finished_arrival_registration_items")
                .contains("report_item.qty")
                .contains("- COALESCE(adjusted.qty, 0)")
                .contains("v_production_fqc_recovery_balance")
                .contains("source_allocation_event_id = allocation_event.id")
                .contains("production_fqc_legacy_exemptions");
    }
}
