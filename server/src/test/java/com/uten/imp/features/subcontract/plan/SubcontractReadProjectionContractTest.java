package com.uten.imp.features.subcontract.plan;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SubcontractReadProjectionContractTest {

    private static final Path JAVA = Path.of("src", "main", "java",
            "com", "uten", "imp", "features");

    @Test
    void warehouseQueueProjectsOnlyExecutableReadyOrLegacyLines() throws IOException {
        String source = read("subcontract/plan/SubcontractMaterialPlanService.java");

        assertThat(source)
                .contains("agg.ready_line_count > 0")
                .contains("agg.ready_outbound_total > 0 OR draft.issue_id IS NOT NULL")
                .contains("pi.preparation_status IN ('LEGACY_READY','READY_OUTBOUND')")
                .contains("pi.planned_qty - pi.issued_qty > 0")
                .contains("hasCurrentAuthority", "subcontract_outbound:execute")
                .contains("outboundActions(canHandleOutbound")
                .contains("COUNT(DISTINCT issue_item.plan_item_id)")
                .contains("issuedNewFlowLines != null && issuedNewFlowLines > 0")
                .contains("notifySubcontractOutboundCompleted(issueId)");
    }

    @Test
    void orderProgressDerivesEffectiveStatusFromExactProductionFacts()
            throws IOException {
        // 2026-09-05 委外收敛：准备中心读模型（SubcontractPreparationTaskAdapter.tasks）
        // 随页面退役删除；车间进度的事实推导契约保留在订货单进度服务。
        String order = read(
                "subcontract/order/SubcontractOrderProgressService.java");

        assertThat(order)
                .contains("CROSS JOIN LATERAL")
                .contains("preparation_status <> 'IN_PREPARATION'")
                .contains("production_plan.material_analysis_id")
                .contains("production_plan.material_analysis_item_id")
                .contains("inspection.source_plan_item_id")
                .contains("inspection.passed_qty > 0")
                .contains("report_item.plan_item_id")
                .contains("report.status = 1")
                .contains("finished_in.doc_type = 'FINISHED_IN'")
                .contains("finished_in.status = 0")
                .contains("THEN 'WAITING_INBOUND'")
                .contains("THEN 'WAITING_FQC'")
                .contains("pi.flow_mode, effective.status");
    }

    @Test
    void orderProgressDerivesWarehouseStatusFromPhysicalQuantitiesBeforeQualityState()
            throws IOException {
        String source = read(
                "subcontract/order/SubcontractOrderProgressService.java");
        int caseStart = source.indexOf("END AS iqc_status,");
        int caseEnd = source.indexOf(
                "END AS warehouse_stock_in_status,", caseStart);
        String warehouseStatusCase = source.substring(caseStart, caseEnd);

        assertThat(warehouseStatusCase)
                .contains("SUM(iq.warehouse_stocked_base_qty)")
                .contains("THEN 'PARTIAL_STOCK_IN'")
                .contains("THEN 'PENDING_STOCK_IN'")
                .contains("THEN 'WAITING_QUALITY'")
                .contains("THEN 'NO_QUALIFIED_STOCK'")
                .contains("THEN 'STOCKED'");
        assertThat(warehouseStatusCase.indexOf("THEN 'PARTIAL_STOCK_IN'"))
                .isLessThan(warehouseStatusCase.indexOf("THEN 'WAITING_QUALITY'"));
        assertThat(warehouseStatusCase.indexOf("THEN 'PENDING_STOCK_IN'"))
                .isLessThan(warehouseStatusCase.indexOf("THEN 'WAITING_QUALITY'"));
    }

    @Test
    void materialAnalysisShowsPreparationBeforeTargetOutboundAndFailsClosedWithoutPlan()
            throws IOException {
        String source = read(
                "production/analysis/MaterialAnalysisSupplyProgressService.java");

        assertThat(source)
                .contains("PREPARATION", "委外目标件准备")
                .contains("TARGET_OUTBOUND", "目标件出仓")
                .contains("purchase ? \"仓库收货\" : \"委外件回厂登记\"")
                .contains("不能解释为无 BOM 无需出仓")
                .contains("前置自制入库仅形成目标件专属出仓占用")
                .doesNotContain("无需发料(委外商自备料)");
        assertThat(source.indexOf("PREPARATION"))
                .isLessThan(source.indexOf("TARGET_OUTBOUND"));
        assertThat(source.toLowerCase())
                .doesNotContain("supplier", "price", "amount", "currency");
    }

    @Test
    void outboundReverseSharesTheReturnDraftLockAndPreservesCapacity() throws IOException {
        String source = read(
                "subcontract/material_issue/SubcontractMaterialIssueService.java");

        assertThat(source)
                .contains("requireReturnCapacityAfterReverse(id, items)")
                .contains("FOR UPDATE OF order_item")
                .contains("receipt.status IN (0, 1)")
                .contains("issue_item.issue_id <> :issueId")
                .contains("红冲后目标件真实出仓额度不足以覆盖已审核或草稿回厂");
    }

    private static String read(String relative) throws IOException {
        return Files.readString(JAVA.resolve(relative), StandardCharsets.UTF_8);
    }
}
