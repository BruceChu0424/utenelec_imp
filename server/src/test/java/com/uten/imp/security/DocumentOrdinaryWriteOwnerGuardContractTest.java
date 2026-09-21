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
        assertThat(method(stock, " approveInternal(")).contains("approveDocumentAfterPrelock(");
        // V584 车间直送给 approveDocumentAfterPrelock 加了一个重载：4 参那个只做
        // 转发，守卫落在 5 参那个上。契约因此按「每个重载要么转发给同名重载、
        // 要么自己带 requireOperationWritable」表述——只断言第一个声明会被一次
        // 纯转发重载悄悄绕过（2026-09-15）。
        var approveOverloads = methods(stock, " approveDocumentAfterPrelock(");
        assertThat(approveOverloads).as("approveDocumentAfterPrelock 重载").isNotEmpty();
        for (String overload : approveOverloads) {
            assertThat(overload).satisfiesAnyOf(
                    body -> assertThat(body).contains("requireOperationWritable("),
                    body -> assertThat(body)
                            .contains("return approveDocumentAfterPrelock("));
        }
        // 直送那一支不是「免检」：它换成了「本单确实是车间直送产物」的形状守卫，
        // 授权在直送审核入口（V585 production_direct_transfer:approve）已经判过。
        assertThat(stock).contains("requireWorkshopDirectTransferDocument(");
        assertThat(method(stock, " reverseInternal(")).contains("requireOperationWritable(");
        assertThat(method(stock, " issue(")).contains("issueAfterPrelock(");
        // 同 approveDocumentAfterPrelock：V584 也给 issueAfterPrelock 加了一个
        // 纯转发重载，守卫落在带 workshopDirectTransfer 的那个上。
        var issueOverloads = methods(stock, " issueAfterPrelock(");
        assertThat(issueOverloads).as("issueAfterPrelock 重载").isNotEmpty();
        for (String overload : issueOverloads) {
            assertThat(overload).satisfiesAnyOf(
                    body -> assertThat(body).contains("requireOperationWritable("),
                    body -> assertThat(body).contains("return issueAfterPrelock("));
        }
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
            String body = method(source, signature);
            if (" approve(".equals(signature) && (
                    relative.equals("features/purchase/receipt/PurchaseReceiptService.java")
                    || relative.equals("features/subcontract/receipt/SubcontractReceiptService.java"))) {
                assertThat(body).contains("approveReceipt(id)");
                body = method(source, " approveReceipt(");
            }
            // V636/ADR-098：委外回厂短交「接受损耗结案」要在不要求 subcontract_waste:approve
            // 的前提下走同一条审核流程，approve( 因此退成薄壳，属主写守卫落在 approveInternal(。
            if (" approve(".equals(signature)
                    && relative.equals("features/subcontract/waste/SubcontractWasteService.java")) {
                assertThat(body).contains("approveInternal(id)");
                body = method(source, " approveInternal(");
            }
            assertThat(body)
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

    /** 同名重载全取（守卫可能只落在其中一个上，另一个纯转发）。 */
    private static List<String> methods(String source, String signature) {
        var declaration = java.util.regex.Pattern.compile(
                "(?m)^\s*(?:public|protected|private)\s+[^\r\n{;]*?"
                        + java.util.regex.Pattern.quote(signature)).matcher(source);
        List<String> bodies = new java.util.ArrayList<>();
        while (declaration.find()) {
            int start = declaration.end() - signature.length();
            int bodyStart = source.indexOf('{', start + signature.length());
            int depth = 0;
            for (int index = bodyStart; index < source.length(); index++) {
                char token = source.charAt(index);
                if (token == '{') depth++;
                if (token == '}' && --depth == 0) {
                    bodies.add(source.substring(start, index + 1));
                    break;
                }
            }
        }
        return bodies;
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
