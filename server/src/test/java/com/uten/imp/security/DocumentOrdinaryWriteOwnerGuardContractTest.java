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
                " update(", " delete(", " approve(", " reverse(", " updateFlags(");
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
        // 仓库发料入口 issueAfterPrelock 只转发给加锁内核 issueLocked 再回显详情；
        // 守卫落在 issueLocked 的仓库分支上(车间直送分支不回显详情，ADR-109)。
        assertThat(method(stock, " issueAfterPrelock(")).contains("issueLocked(");
        assertThat(method(stock, " issueLocked(")).contains("requireOperationWritable(");
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
            // ADR-109 / permissions-06：生产计划单张审核 / 删除与服务端批量审核 / 删除共用同一个
            // 加锁内核(approveLocked / deleteLocked)，属主写守卫落在内核里，单张入口只转发。
            if (relative.equals("features/production/plan/ProductionPlanService.java")
                    && (" approve(".equals(signature) || " delete(".equals(signature))) {
                String locked = " approve(".equals(signature) ? "approveLocked" : "deleteLocked";
                assertThat(body).contains(locked + "(id)");
                body = method(source, " " + locked + "(");
                // V700：实际产出追加计划的审核转给追加计划服务(守卫按追加计划的计划负责人落在
                // 那边)，普通计划走 approveOrdinaryLocked。两条分支都必须有属主写守卫。
                if ("approveLocked".equals(locked) && body.contains("approveOrdinaryLocked(id)")) {
                    assertThat(body).contains("actualOutputSupplements.getObject().approve(");
                    assertThat(method(source(
                            "features/production/dailyreport/ActualOutputSupplementService.java"),
                            " approve("))
                            .as("actual output supplement approve owner guard")
                            .contains("access.requireWritable(uuid(r,\"plan_maker_id\")");
                    body = method(source, " approveOrdinaryLocked(");
                }
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
