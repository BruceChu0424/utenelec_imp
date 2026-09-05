package com.uten.imp.features.stock;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertTrue;

class ProductionLinkedStockDocumentServiceContractTest {

    @Test
    void genericUpdateAndDeleteRejectProductionOwnedDocuments()
            throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/stock/StockDocService.java"));

        int update = source.indexOf(
                "public StockDocDetail update(UUID id");
        int delete = source.indexOf("public void delete(UUID id)");
        int approve = source.indexOf("public StockDocDetail approve(UUID id)");

        assertTrue(update >= 0 && delete > update && approve > delete);
        assertTrue(source.substring(update, delete).contains(
                "rejectGenericMutationOfProductionDocument(d)"));
        assertTrue(source.substring(delete, approve).contains(
                "rejectGenericMutationOfProductionDocument(d)"));
        assertTrue(source.contains("ErrorCode.CONFLICT"));
        assertTrue(source.contains("fn_is_production_linked_stock_document"));
        assertTrue(source.contains("productionLinked, canEdit, canDelete"));
    }

    @Test
    void productionDrawCannotBeApprovedWithoutAtomicIssue()
            throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/stock/StockDocService.java"));

        assertTrue(source.contains(
                "&& isProductionLinked(id)\n"
                        + "                && !allowProductionDrawApproveAndIssue"));
        assertTrue(source.contains(
                "生产领料单不能单独审核；请使用“出库”一次完成审核与实物出库"));
        assertTrue(source.contains(
                "生产领料明细缺少唯一且一致的物料需求→执行工单 UUID 映射，禁止出库"));
        assertTrue(source.contains(
                "production_planning_package_document_items mapping"));
        assertTrue(source.contains(
                "demand.execution_segment_id"));
        assertTrue(source.contains(
                "header.execution_segment_id"));
        assertTrue(!source.contains(
                "AND execution_segment_id IS NULL"));
        assertTrue(source.contains(
                "if (document.getStatus() == STATUS_APPROVED)"));
        assertTrue(source.contains("return issue(id, req);"));
        assertTrue(source.contains("approveInternal(id, false, true)"));
    }

    @Test
    void everyIssueSliceRefreshesExactSegmentReadiness() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/stock/StockDocService.java"));
        int issue = source.indexOf("public StockDocDetail issue(UUID id");
        int reverse = source.indexOf("public StockDocDetail reverseIssue(", issue);
        String method = source.substring(issue, reverse);

        assertTrue(method.contains("notifyProductionDrawIssued("));
        assertTrue(!method.contains(
                "if (d.getIssueStatus() == ISSUE_FULL)"));
    }
}
