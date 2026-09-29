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
         * 待发料出仓 / 出仓等子件到货(ADR-103) / 委外加工中 / 部分回厂 / 分批等待中 / 回厂短交待判定
         * (ADR-098); 委外申请行按路线 B 锁态细分为等子件到货 WAITING_COMPONENT_STOCK / 子件有货可下单
         * COMPONENT_STOCK_READY(ADR-103); 前置自制合成行为车间状态; 其余等于 taskStatus。
         */
        String displayStage,
        /**
         * ADR-103 路线 B: 单一子件委外申请行的子件可动用合计(多明细取 MIN, 给「可发数量」提示);
         * 普通委外件 / 多子件先自制的委外件 / 非申请行为 null。
         */
        BigDecimal componentAvailableQty,
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
        List<java.util.Map<String, Object>> lines) {

    public FulfillmentTaskRow withSources(List<SubcontractTaskSource> value) {
        return new FulfillmentTaskRow(
                department, taskId, packageId, planId, planNo, warehouseId, warehouseName,
                goodsId, goodsCode, goodsName, spec, colorId, colorName, unitId, unitName,
                supplyRoute, requiredQty, allocatedQty, fulfilledQty, supplyPeggedQty, openQty,
                taskStatus, needDate, expectedDate, exceptionCode, updatedAt,
                actionDocType, actionDocId, actionDocNo, actionDocItemId, actionDocStatus,
                actionDocCanView, actionDocCanEdit, actionDocRestricted, goodsCount, openLineCount,
                actionItemIds, issuedAt, canCreateOrder, displayStage, componentAvailableQty,
                List.copyOf(value), materialsDefined, productionProductCode, productionProductName, materialRequestNo,
                workshopName, workerName, drawBatchNo,
                lines == null ? List.of() : List.copyOf(lines));
    }

    /** 按单据归组的行（采购/委外）：一行代表一张申请或订货单的整批明细。 */
    public boolean isDocumentGrouped() {
        return goodsCount > 1 || openLineCount > 1 || actionItemIds.size() > 1;
    }
}
