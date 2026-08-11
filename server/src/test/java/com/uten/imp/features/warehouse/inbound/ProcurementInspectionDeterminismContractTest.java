package com.uten.imp.features.warehouse.inbound;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementInspectionDeterminismContractTest {

    private static final Path JAVA = Path.of("src/main/java/com/uten/imp");

    @Test
    void dispositionUsesCanonicalDimensionThenWholeReceiptRowLocking() throws Exception {
        String source = source(
                "features/warehouse/inbound/ProcurementInspectionService.java");

        assertOrdered(source,
                "lockReceiptMutationDimensions(receiptType, receiptId);",
                "FROM procurement_inspection_items");
        assertThat(source)
                .contains("WHERE receipt_type = :rt AND receipt_id = :rid")
                .contains("ORDER BY id\n                        FOR UPDATE")
                .contains("lockPurchaseReceiptMutationDimensions(receiptId)")
                .contains("lockSubcontractReceiptMutationDimensions(receiptId)")
                .contains("if (isReplay(eventId, inspectionItemId, action, requested, reason)) {")
                .contains("wakeIfWholeReceiptResolved(receiptType, receiptId");
    }

    @Test
    void reversalPreservesAppendOnlyEvidenceAndV222Projection() throws Exception {
        String source = source(
                "features/warehouse/inbound/ProcurementInspectionService.java");

        assertThat(source)
                .contains("receivedAmount, receivedBase, BigDecimal.ZERO, passed")
                .contains("SET passed_base_qty = 0,")
                .contains("failed_base_qty = 0,")
                .contains("status = 'REVERSED'")
                .contains("\"RECEIPT_REVERSED\", passed");
    }

    @Test
    void planningConsumptionUsesQualifiedQtyWhileInboundUsesPhysicalOutstandingQty()
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
                .contains("inspection.passed_base_qty")
                .contains("inspection.status = 'RESOLVED'")
                .contains("AND status = 1");
        assertThat(readiness)
                .contains("THEN inspection")
                .contains(".passed_base_qty")
                .contains("WHEN inspection.status =")
                .contains("'RESOLVED'")
                .contains("receipt.doc_type = 'FINISHED_IN'")
                .contains("AND receipt.status = 1")
                .contains("FOR UPDATE OF peg")
                .doesNotContain("FOR UPDATE OF peg, receipt_item, receipt");
        assertThat(analysis)
                .contains("THEN inspection.passed_base_qty")
                .contains("COALESCE(i.qty,0)-COALESCE(i.received_qty,0)")
                .contains("o.is_closed = FALSE")
                .contains("到货质检存在不合格且原采购需求已无在途")
                .contains("到货质检存在不合格且原委外需求已无在途")
                .contains("inspection.failed_base_qty > 0")
                .contains("action.status IN ('CREATED','IN_PROGRESS','DONE')")
                .contains("request.is_closed = TRUE")
                .contains("application.is_closed = TRUE");
        assertThat(commands)
                .contains("THEN inspection.passed_base_qty")
                .doesNotContain("COALESCE(item.received_qty,0)");
    }

    private static void assertOrdered(String source, String first, String second) {
        assertThat(source.indexOf(first)).isGreaterThanOrEqualTo(0);
        assertThat(source.indexOf(second)).isGreaterThan(source.indexOf(first));
    }

    private static String source(String relative) throws Exception {
        return Files.readString(JAVA.resolve(relative), StandardCharsets.UTF_8);
    }
}
