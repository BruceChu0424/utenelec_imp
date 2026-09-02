package com.uten.imp.features.warehouse.inbound;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementInspectionDeterminismContractTest {

    private static final Path JAVA = Path.of("src/main/java/com/uten/imp");

    @Test
    void dispositionOnlyReleasesWhileWarehouseCommandOwnsStockAndProductionSideEffects()
            throws Exception {
        String source = source(
                "features/warehouse/inbound/ProcurementInspectionService.java");
        String stockIn = source(
                "features/warehouse/inbound/ProcurementIqcStockInService.java");
        int dispositionStart = source.indexOf("public void dispose(");
        int dispositionEnd = source.indexOf(
                "\n    private void publishIqcStockInPending", dispositionStart);
        String disposition = source.substring(dispositionStart, dispositionEnd);

        assertOrdered(source,
                "lockReceiptMutationDimensions(receiptType, receiptId);",
                "FROM procurement_inspection_items");
        assertThat(disposition)
                .contains("WHERE receipt_type = :rt AND receipt_id = :rid")
                .contains("ORDER BY id\n                        FOR UPDATE")
                .contains("Boolean replayRequiresWarehouseStockIn = replayRequiresWarehouseStockIn(")
                .contains("switch (replayNotification(action, replayRequiresWarehouseStockIn))")
                .contains("case NONE ->")
                .contains("boolean wholeReceiptResolved = allResolved(receiptType, receiptId)")
                .contains("if (\"PASS\".equals(action))")
                .contains("publishIqcStockInPending(")
                .contains("releasedAmount, releasedWeight, releasedWeightUnitId")
                .doesNotContain("stockService.recordMovement(")
                .doesNotContain("advanceProductionAfterInspectionPass(")
                .doesNotContain("attributeInspectionPass(");
        assertThat(stockIn)
                .contains("event.released_amount_local")
                .contains("event.released_weight")
                .contains("stockService.recordMovement(")
                .contains("preplanAnalysisPeg.attributeInspectionStockIn(")
                .contains("advanceProductionAfterStockIn(")
                .contains("purchaseSupply.afterPurchaseInspectionStockInConfirmed(")
                .contains("subcontractSupply.afterSubcontractInspectionStockInConfirmed(");
    }

    @Test
    void receiptCreatesOneReceiptScopedPendingNoticeAfterAllInspectionLines() throws Exception {
        String source = source(
                "features/warehouse/inbound/ProcurementInspectionService.java");
        int receiveStart = source.indexOf("public void receive(");
        int receiveEnd = source.indexOf("\n    /**", receiveStart);
        String receive = source.substring(receiveStart, receiveEnd);

        assertOrdered(receive,
                "for (ReceivedLine l : lines)",
                "if (!lines.isEmpty())");
        assertThat(receive)
                .containsOnlyOnce("outbox.publishOnce(")
                .contains("EVENT_IQC_PENDING,")
                .contains("\"PROCUREMENT_INSPECTION\",")
                .contains("Map.of(\"receiptType\", receiptType)")
                .contains("EVENT_IQC_PENDING + ':' + receiptId");
    }

    @Test
    void reversalUsesOnlyWarehouseStockedProjectionAndKeepsQualityEvidence() throws Exception {
        String source = source(
                "features/warehouse/inbound/ProcurementInspectionService.java");

        assertThat(source)
                .contains("warehouse_stocked_base_qty,")
                .contains("warehouse_stocked_amount_local,")
                .contains("warehouse_stocked_weight,")
                .contains("SET passed_base_qty = 0,")
                .contains("failed_base_qty = 0,")
                .contains("warehouse_stocked_base_qty = 0,")
                .contains("status = 'REVERSED'")
                .contains("\"RECEIPT_REVERSED\", stocked");
    }

    @Test
    void readinessUsesWarehouseStockedQtyWhilePlanningKeepsQualityDispositionFacts()
            throws Exception {
        String purchaseTransition = source(
                "features/production/fulfillment/"
                        + "ProductionPurchaseSupplyTransitionService.java");
        String readiness = source(
                "features/production/fulfillment/"
                        + "ProductionExecutionReadinessService.java");
        String analysis = source(
                "features/production/analysis/MaterialAnalysisService.java");
        String commands = source(
                "features/production/analysis/MaterialAnalysisCommandService.java");

        assertThat(purchaseTransition)
                .contains("inspection.warehouse_stocked_base_qty")
                .contains("inspection.status IN (")
                .contains("'PARTIAL', 'RESOLVED'")
                .contains("inspection.warehouse_stocked_base_qty > 0")
                .contains(":IQC_PASS:")
                .contains("AND status = 1");
        assertThat(readiness)
                .contains("THEN inspection")
                .contains(".warehouse_stocked_base_qty")
                .contains("WHEN inspection.status IN (")
                .contains("'PARTIAL', 'RESOLVED'")
                .contains("receipt.doc_type = 'FINISHED_IN'")
                .contains("AND receipt.status = 1")
                .contains("FOR UPDATE OF peg")
                .doesNotContain("FOR UPDATE OF peg, receipt_item, receipt");
        assertThat(occurrences(readiness, "'PARTIAL', 'RESOLVED'"))
                .isEqualTo(2);
        assertThat(analysis)
                .contains("THEN inspection.warehouse_stocked_base_qty")
                .contains("inspection.passed_base_qty")
                .contains("> inspection.warehouse_stocked_base_qty")
                .doesNotContain("THEN inspection.passed_base_qty")
                .contains("COALESCE(i.qty,0)-COALESCE(i.received_qty,0)")
                .contains("o.is_closed = FALSE")
                .contains("到货质检存在不合格且原采购需求已无在途")
                .contains("到货质检存在不合格且原委外需求已无在途")
                .contains("inspection.failed_base_qty > 0")
                .contains("action.status IN ('CREATED','IN_PROGRESS','DONE')")
                .contains("request.is_closed = TRUE")
                .contains("application.is_closed = TRUE");
        assertThat(commands)
                .contains("THEN inspection.warehouse_stocked_base_qty")
                .doesNotContain("THEN inspection.passed_base_qty")
                .doesNotContain("COALESCE(item.received_qty,0)");
    }

    private static void assertOrdered(String source, String first, String second) {
        assertThat(source.indexOf(first)).isGreaterThanOrEqualTo(0);
        assertThat(source.indexOf(second)).isGreaterThan(source.indexOf(first));
    }

    private static int occurrences(String source, String token) {
        return source.split(java.util.regex.Pattern.quote(token), -1).length - 1;
    }

    private static String source(String relative) throws Exception {
        return Files.readString(JAVA.resolve(relative), StandardCharsets.UTF_8);
    }
}
