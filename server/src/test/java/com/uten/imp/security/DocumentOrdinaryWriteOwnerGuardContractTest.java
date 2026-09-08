package com.uten.imp.security;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/** Guards the ordinary-write inventory behind owner responsibility, not manual visibility. */
class DocumentOrdinaryWriteOwnerGuardContractTest {

    private static final Path JAVA = Path.of("src/main/java/com/uten/imp");

    @Test
    void salesOrdinaryMutationsKeepOwnerWriteGuards() throws Exception {
        assertMethods("features/sales/quote/SalesQuoteService.java",
                " update(", " delete(", " approve(", " reverse(", " convertToOrder(");
        assertMethods("features/sales/order/SalesOrderService.java",
                " update(", " delete(", " approve(", " reverse(", " changeQty(",
                " cancel(", " setPartialShipmentConfirmation(", " setLinePriority(",
                " yieldReservation(", " toggleStopped(");
        assertMethods("features/sales/shipment/SalesShipmentService.java",
                " update(", " delete(", " approve(", " reverse(");
        assertMethods("features/sales/other_shipment/SalesOtherShipmentService.java",
                " reverse(");
        String historicalOther=source("features/sales/other_shipment/SalesOtherShipmentService.java");
        for(String retired:List.of(" create("," update("," delete("," approve(")) {
            assertThat(method(historicalOther,retired)).contains("throw retiredWrite()")
                    .doesNotContain("recordMovement(","shipmentRepo.save(","itemRepo.delete");
        }
        assertMethods("features/sales/ret/SalesReturnService.java",
                " update(", " delete(", " approve(", " reverse(", " setDisposition(");
    }

    @Test
    void procurementAndProductionOrdinaryMutationsKeepOwnerWriteGuards() throws Exception {
        assertMethods("features/purchase/order/PurchaseOrderService.java",
                " update(", " delete(", " reverse(", " requireFinanceSubmitterWritable(");
        assertMethods("features/purchase/receipt/PurchaseReceiptService.java",
                " update(", " delete(", " approve(", " reverse(");
        assertMethods("features/purchase/ret/PurchaseReturnService.java",
                " update(", " delete(", " approve(", " reverse(");

        for (String relative : List.of(
                "features/subcontract/inquiry/SubcontractInquiryService.java",
                "features/subcontract/material_return/SubcontractMaterialReturnService.java",
                "features/subcontract/receipt/SubcontractReceiptService.java",
                "features/subcontract/ret/SubcontractReturnService.java",
                "features/subcontract/waste/SubcontractWasteService.java")) {
            assertMethods(relative, " update(", " delete(", " approve(", " reverse(");
        }
        assertMethods("features/subcontract/order/SubcontractOrderService.java",
                " update(", " delete(", " reverse(", " requireFinanceSubmitterWritable(");
        assertMethods("features/subcontract/material_issue/SubcontractMaterialIssueService.java",
                " update(", " delete(", " approve(", " reverse(");

        assertMethods("features/production/plan/ProductionPlanService.java",
                " update(", " delete(", " reverse(", " updateFlags(");
        assertMethods("features/production/dailyreport/ProductionDailyReportService.java",
                " update(", " delete(");
    }

    @Test
    void financeCrudAndManualStockLifecycleKeepOwnerWriteGuards() throws Exception {
        for (String relative : List.of(
                "features/finance/payment/FinancePaymentService.java",
                "features/finance/receipt/FinanceReceiptService.java",
                "features/finance/expense/FinanceExpenseService.java",
                "features/finance/bank_transfer/FinanceBankTransferService.java",
                "features/finance/other_income/FinanceOtherIncomeService.java")) {
            assertMethods(relative, " update(", " delete(");
        }

        assertMethods("features/stock/StockDocService.java", " update(", " delete(");
        String stock = source("features/stock/StockDocService.java");
        assertThat(method(stock, " approveInternal(")).contains("requireOperationWritable(");
        assertThat(method(stock, " reverseInternal(")).contains("requireOperationWritable(");
        assertThat(method(stock, " issue(")).contains("issueAfterPrelock(");
        assertThat(method(stock, " issueAfterPrelock(")).contains("requireOperationWritable(");
        assertThat(method(stock, " reverseIssue(")).contains("requireOperationWritable(");
        assertThat(method(stock, " requireOperationWritable(")).contains(
                "access.requireWritable(document.getMakerId(), message)",
                "productionStockTaskAccess.requireWarehouseTaskAccess(message)");
    }

    @Test
    void submissionGuardRunsBeforeFinanceSnapshotValidation() throws Exception {
        String source = source(
                "features/finance/procurement/ProcurementFinanceApprovalService.java");
        String submit = method(source, " submit(");
        assertThat(submit.indexOf("port.requireFinanceSubmitterWritable(orderId)"))
                .isGreaterThanOrEqualTo(0)
                .isLessThan(submit.indexOf("port.lockAndValidateFinanceSubmission(orderId)"));
        assertThat(method(source, " approveBatch("))
                .doesNotContain("requireFinanceSubmitterWritable");
        assertThat(method(source, " rejectBatch("))
                .doesNotContain("requireFinanceSubmitterWritable");
    }

    private static void assertMethods(String relative, String... signatures) throws Exception {
        String source = source(relative);
        for (String signature : signatures) {
            assertThat(method(source, signature))
                    .as("%s in %s", signature.trim(), relative)
                    .containsAnyOf(
                            "access.requireWritable(",
                            "accessPolicy.requireWritable(",
                            "requireWritable",
                            "requireIssueWritable(");
        }
    }

    private static String source(String relative) throws Exception {
        return Files.readString(JAVA.resolve(relative), StandardCharsets.UTF_8);
    }

    private static String method(String source, String signature) {
        var declaration = java.util.regex.Pattern.compile(
                "(?m)^\\s*(?:public|protected|private)\\s+[^\\r\\n{;]*?"
                        + java.util.regex.Pattern.quote(signature)).matcher(source);
        int start = declaration.find() ? declaration.end() - signature.length() : -1;
        assertThat(start).as("method %s", signature.trim()).isGreaterThanOrEqualTo(0);
        int bodyStart = source.indexOf('{', start + signature.length());
        int depth = 0;
        for (int index = bodyStart; index < source.length(); index++) {
            char token = source.charAt(index);
            if (token == '{') depth++;
            if (token == '}' && --depth == 0) return source.substring(start, index + 1);
        }
        throw new IllegalStateException("Unclosed method: " + signature.trim());
    }

}
