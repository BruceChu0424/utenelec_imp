package com.uten.imp.features.operations.workbench;

import com.uten.imp.application.port.SubcontractTaskSource;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public record FulfillmentTaskRow(
        String department,
        UUID taskId,
        UUID packageId,
        UUID planId,
        String planNo,
        UUID warehouseId,
        String warehouseName,
        UUID goodsId,
        String goodsCode,
        String goodsName,
        String spec,
        UUID colorId,
        String colorName,
        UUID unitId,
        String unitName,
        String supplyRoute,
        BigDecimal requiredQty,
        BigDecimal allocatedQty,
        BigDecimal fulfilledQty,
        BigDecimal supplyPeggedQty,
        BigDecimal openQty,
        String taskStatus,
        LocalDate needDate,
        LocalDate expectedDate,
        String exceptionCode,
        OffsetDateTime updatedAt,
        String actionDocType,
        UUID actionDocId,
        String actionDocNo,
        UUID actionDocItemId,
        String actionDocStatus,
        boolean actionDocCanView,
        boolean actionDocCanEdit,
        boolean actionDocRestricted,
        long goodsCount,
        long openLineCount,
        List<String> actionItemIds,
        OffsetDateTime issuedAt,
        boolean canCreateOrder,
        /**
         * 展示阶段(display_stage)：与状态列的表头筛选/排序同源。委外订货单在财务已通过之后细分为
         * 回厂短交待判定 / 分批等待中 / 容差内待结案 / 已回厂待入库 / 可领料 / 已提交领料·待仓库发料
         * / 部分回厂 / 委外加工中 / 等待物料(ADR-098 / ADR-143 §4.1); 待分解的委外申请里有委外件
         * 缺 BOM 时为 BOM_MISSING「缺 BOM·已通知研发」(ADR-143 §二.3, 不能生成订货单);
         * 其余等于 taskStatus。
         */
        String displayStage,
        List<SubcontractTaskSource> sources,
        boolean materialsDefined,
        String productionProductCode,
        String productionProductName,
        String materialRequestNo,
        /** 领料车间名（仓库 DRAW 段：stock_documents.department_id → departments.name；其他段 null）。 */
        String workshopName,
        /** 领料负责人名（仓库 DRAW 段：stock_documents.worker_id → employees.full_name；其他段 null）。 */
        String workerName,
        /** 领料批次号（仓库 DRAW 段：批量领料提交时整批写同一批次号；其他段 null）。 */
        String drawBatchNo,
        /**
         * 行级明细（仓库 DRAW 段：货品×数量的 jsonb 数组；前端按「批次×货品」
         * 拆分/合并待领任务行）。其他段恒空列表。
         */
        List<java.util.Map<String, Object>> lines,
        /**
         * 委外申请缺 BOM 时该委外件未完成的「完善 BOM」研发任务编号(多个用「、」连接);
         * 还没有未完成研发任务或不缺 BOM 时为空(ADR-143 §二.3)。
         */
        String rdTaskNo,
        /** 委外申请里缺 BOM 的明细 id(「通知研发完善」逐条调用); 不缺 BOM 时为空列表。 */
        List<String> bomMissingItemIds) {

    public FulfillmentTaskRow withSources(List<SubcontractTaskSource> value) {
        return new FulfillmentTaskRow(
                department, taskId, packageId, planId, planNo, warehouseId, warehouseName,
                goodsId, goodsCode, goodsName, spec, colorId, colorName, unitId, unitName,
                supplyRoute, requiredQty, allocatedQty, fulfilledQty, supplyPeggedQty, openQty,
                taskStatus, needDate, expectedDate, exceptionCode, updatedAt,
                actionDocType, actionDocId, actionDocNo, actionDocItemId, actionDocStatus,
                actionDocCanView, actionDocCanEdit, actionDocRestricted, goodsCount, openLineCount,
                actionItemIds, issuedAt, canCreateOrder, displayStage,
                List.copyOf(value), materialsDefined, productionProductCode, productionProductName, materialRequestNo,
                workshopName, workerName, drawBatchNo,
                lines == null ? List.of() : List.copyOf(lines),
                rdTaskNo, bomMissingItemIds == null ? List.of() : List.copyOf(bomMissingItemIds));
    }

    /** 按单据归组的行（采购/委外）：一行代表一张申请或订货单的整批明细。 */
    public boolean isDocumentGrouped() {
        return goodsCount > 1 || openLineCount > 1 || actionItemIds.size() > 1;
    }
}
