package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.ProductionCompletionReversePort;
import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.features.production.execution.ProductionCompletionReverseService;
import com.uten.imp.features.production.fulfillment.ProductionPurchaseSupplyTransitionService;
import com.uten.imp.features.production.fulfillment.ProductionSubcontractSupplyTransitionService;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class MaterialAnalysisSupplyWakeupHookContractTest {

    @Test
    void optionalWakeupHooksRemainDefaultForExistingTestDoubles() throws Exception {
        assertThat(ProductionSupplyTransitionPort.class.getMethod(
                "afterPurchaseReceiptReversed", UUID.class).isDefault()).isTrue();
        assertThat(ProductionSubcontractSupplyTransitionPort.class.getMethod(
                "afterSubcontractReceiptReversed", UUID.class).isDefault()).isTrue();
        assertThat(ProductionSupplyTransitionPort.class.getMethod(
                "afterPurchaseInspectionPassed",
                UUID.class, UUID.class, UUID.class).isDefault()).isTrue();
        assertThat(ProductionSubcontractSupplyTransitionPort.class.getMethod(
                "afterSubcontractInspectionPassed",
                UUID.class, UUID.class, UUID.class).isDefault()).isTrue();
        assertThat(ProductionCompletionReversePort.class.getMethod(
                "afterFinishedInboundReversed", UUID.class, UUID.class).isDefault()).isTrue();
    }

    @Test
    void productionAfterHookImplementationsRequireTheSourceTransaction()
            throws Exception {
        assertMandatory(
                ProductionPurchaseSupplyTransitionService.class,
                "afterPurchaseReceiptReversed", UUID.class);
        assertMandatory(
                ProductionSubcontractSupplyTransitionService.class,
                "afterSubcontractReceiptReversed", UUID.class);
        assertMandatory(
                ProductionPurchaseSupplyTransitionService.class,
                "afterPurchaseInspectionPassed",
                UUID.class, UUID.class, UUID.class);
        assertMandatory(
                ProductionSubcontractSupplyTransitionService.class,
                "afterSubcontractInspectionPassed",
                UUID.class, UUID.class, UUID.class);
        assertMandatory(
                ProductionCompletionReverseService.class,
                "afterFinishedInboundReversed", UUID.class, UUID.class);
    }

    @Test
    void purchaseAndSubcontractPassSlicesAdvanceBeforeWholeReceiptClosure()
            throws Exception {
        String inspection = source(
                "features/warehouse/inbound/ProcurementInspectionService.java");
        String purchase = source(
                "features/production/fulfillment/"
                        + "ProductionPurchaseSupplyTransitionService.java");
        String subcontract = source(
                "features/production/fulfillment/"
                        + "ProductionSubcontractSupplyTransitionService.java");

        assertThat(inspection)
                .contains("boolean wholeReceiptResolved = allResolved(receiptType, receiptId)")
                .contains("if (\"PASS\".equals(action))")
                .contains("advanceProductionAfterInspectionPass(")
                .contains("if (!wholeReceiptResolved || alreadyWoken(receiptType, receiptId))")
                .contains("wakeProduction(receiptType, receiptId)")
                .contains("purchaseSupply.onPurchaseReceiptApproved(receiptId)")
                .contains("subcontractSupply.onSubcontractReceiptApproved(receiptId)");
        assertThat(inspection.lastIndexOf("advanceProductionAfterInspectionPass("))
                .isGreaterThan(inspection.indexOf(
                        "appendEvent(eventId, inspectionItemId, action, requested, reason, actor, now)"));
        assertOrdered(inspection,
                "advanceProductionAfterInspectionPass(",
                "wakeIfWholeReceiptResolved(");
        assertThat(purchase).contains(
                "materialAnalysisWakeup.afterPurchaseReceiptApproved(receiptId)")
                .contains("materialAnalysisWakeup.afterPurchaseInspectionPassed(")
                .contains("advancePurchaseReceipt(receiptId, dispositionEventId);");
        assertThat(subcontract).contains(
                "materialAnalysisWakeup.afterSubcontractReceiptApproved(receiptId)")
                .contains("materialAnalysisWakeup.afterSubcontractInspectionPassed(")
                .contains("onSubcontractReceiptApproved(receiptId);");
    }

    @Test
    void everyReversalRefreshRunsAfterItsPhysicalStockDeduction() throws Exception {
        String purchase = source("features/purchase/receipt/PurchaseReceiptService.java");
        String subcontract = source(
                "features/subcontract/receipt/SubcontractReceiptService.java");
        String stock = source("features/stock/StockDocService.java");

        assertOrdered(purchase,
                "inspectionService.reverseResolvedStock(",
                "productionSupply.afterPurchaseReceiptReversed(id)");
        assertOrdered(subcontract,
                "inspectionService.reverseResolvedStock(",
                "productionSupply.afterSubcontractReceiptReversed(id)");
        assertOrdered(stock,
                "applyStockEffect(d, items, -1)",
                "productionCompletionReverse.afterFinishedInboundReversed(");
    }

    @Test
    void makeApprovalWakesAfterFinishedInboundStockAndCompletionTransition()
            throws Exception {
        String stock = source("features/stock/StockDocService.java");
        String completion = source(
                "features/production/execution/ProductionCompletionReverseService.java");

        assertOrdered(stock,
                "applyStockEffect(d, items, +1)",
                "productionCompletionReverse.afterFinishedInboundApproved(");
        assertOrdered(completion,
                "readiness.onFinishedInboundApproved(",
                "materialAnalysisWakeup.afterFinishedInboundApproved(stockDocumentId)");
    }

    private static void assertOrdered(String source, String first, String second) {
        assertThat(source.indexOf(first)).isGreaterThanOrEqualTo(0);
        assertThat(source.indexOf(second)).isGreaterThan(source.indexOf(first));
    }

    private static void assertMandatory(
            Class<?> type, String methodName, Class<?>... parameterTypes)
            throws Exception {
        Transactional transactional = type.getMethod(methodName, parameterTypes)
                .getAnnotation(Transactional.class);
        assertThat(transactional).isNotNull();
        assertThat(transactional.propagation()).isEqualTo(Propagation.MANDATORY);
    }

    private static String source(String relative) throws Exception {
        return Files.readString(Path.of("src/main/java/com/uten/imp", relative),
                StandardCharsets.UTF_8);
    }
}
