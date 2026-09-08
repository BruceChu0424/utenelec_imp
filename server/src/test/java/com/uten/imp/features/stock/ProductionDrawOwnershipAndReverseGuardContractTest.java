package com.uten.imp.features.stock;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionDrawOwnershipAndReverseGuardContractTest {

    private static final Path MAIN = Path.of("src/main/java/com/uten/imp/features");

    @Test
    void automaticDrawKeepsWorkerUnassignedWhenSegmentHasNoResponsibleEmployee()
            throws Exception {
        String packageCommand = source(
                "production/mrp/ProductionExecutionPackageCommandService.java");
        String packageDraw = slice(
                packageCommand,
                "private MrpGenerateResult createDraw(",
                "private void createMakeSupplyPegs(");
        assertThat(packageDraw)
                .contains("document.setWorkerId(segment.getResponsibleEmployeeId());")
                .contains("document.setMakerId(currentUser.requireEmployeeId());")
                .doesNotContain("? currentUser.requireEmployeeId()");

        String readiness = source(
                "production/fulfillment/ProductionExecutionReadinessService.java");
        String readinessDraw = slice(
                readiness,
                "private StockDocument createDraw(",
                "private UUID addDrawItem(");
        assertThat(readinessDraw)
                .contains("document.setWorkerId(responsibleEmployeeId);")
                .contains("document.setMakerId(currentUser.requireEmployeeId());")
                .doesNotContain("? currentUser.requireEmployeeId()");
    }

    @Test
    void invalidHistoricalIssueDimensionFailsBeforeLedgerReverse()
            throws Exception {
        String stock = source("stock/StockDocService.java");
        int reverse = stock.indexOf("public StockDocDetail reverseIssue(");
        int dimensionGuard = stock.indexOf(
                "requireReverseIssueDimensions(d, items, req)", reverse);
        int ledgerReverse = stock.indexOf(
                "productionMaterialLedger.prepareReverseIssue(", reverse);

        assertThat(reverse).isGreaterThanOrEqualTo(0);
        assertThat(dimensionGuard).isGreaterThan(reverse);
        assertThat(ledgerReverse).isGreaterThan(dimensionGuard);
        assertThat(stock)
                .contains("禁止普通取消出库；请走专用领料历史对账修复")
                .doesNotContain("仅回减历史误增的 issued_qty")
                .doesNotContain(
                        "if (d.getWarehouseId() == null || baseQty.signum() == 0) return");
    }

    @Test
    void cancellationIsAllowedBeforeFirstReportAndBlockedAfterReport()
            throws Exception {
        String ledger = source(
                "stock/allocation/ProductionMaterialStockLedgerService.java");
        String guard = slice(
                ledger,
                "private void requireReverseIssueBeforeDispatch(",
                "@Transactional(propagation = Propagation.MANDATORY)\n"
                        + "    public void completeReverseIssue");

        assertThat(guard)
                .contains("production_daily_report_items")
                .contains("report.status IN (0, 1)")
                .contains("issueCancellationBlocked(")
                .contains("SEGMENT_IN_PROGRESS")
                .contains("SEGMENT_COMPLETED")
                .doesNotContain("SEGMENT_DISPATCHED,");
    }

    @Test
    void productionDrawIssueGuardsApplyOnlyToProductionLinkedDocuments()
            throws Exception {
        String stock = source("stock/StockDocService.java");
        String issue = slice(
                stock,
                "public StockDocDetail issue(UUID id, StockDocIssueRequest req)",
                "/** 取消出库：幂等预检后先恢复物理库存，再对称恢复 allocation.consumed_qty。 */");
        // 两个生产侧守卫（已审关联计划 + 逐行唯一执行段映射）必须包在
        // isProductionLinked 分支里：手工单没有这些事实，不套用生产校验。
        assertThat(issue)
                .contains("if (isProductionLinked(d.getId())) {")
                .contains("requireApprovedLinkedProductionPlan(d);")
                .contains("requireExactProductionDrawSegmentMappings(id);");
        int branch = issue.indexOf("if (isProductionLinked(d.getId())) {");
        int linkedPlan = issue.indexOf("requireApprovedLinkedProductionPlan(d);");
        int exactMapping = issue.indexOf(
                "requireExactProductionDrawSegmentMappings(id);");
        assertThat(branch).isGreaterThanOrEqualTo(0);
        assertThat(linkedPlan).isGreaterThan(branch);
        assertThat(exactMapping).isGreaterThan(linkedPlan);

        // 审核：生产链 DRAW 禁止单独审核（出库即审核口径）；DRAW/成品入库
        // 的「必须关联已审计划」保持无条件（生产领料域归生产链所有，手工
        // 入口已在任务中心撤除，历史草稿在此得到一致的拒绝文案）。
        String approve = slice(
                stock,
                "private StockDocDetail approveInternal(",
                "/** 红冲：1→-1，反向冲销库存。DRAW 有已出库量时须先取消全部出库。 */");
        assertThat(approve)
                .contains("isProductionLinked(id)\n                && !allowProductionDrawApproveAndIssue")
                .contains("if (\"DRAW\".equals(d.getDocType()) "
                        + "|| \"FINISHED_IN\".equals(d.getDocType())) {\n"
                        + "            requireApprovedLinkedProductionPlan(d);");
    }

    private static String source(String relative) throws Exception {
        return Files.readString(MAIN.resolve(relative), StandardCharsets.UTF_8)
                .replace("\r\n", "\n");
    }

    private static String slice(String source, String startMarker, String endMarker) {
        int start = source.indexOf(startMarker);
        int end = source.indexOf(endMarker, start + startMarker.length());
        assertThat(start).isGreaterThanOrEqualTo(0);
        assertThat(end).isGreaterThan(start);
        return source.substring(start, end);
    }
}
