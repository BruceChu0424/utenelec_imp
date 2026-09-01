package com.uten.imp.features.subcontract.plan.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 委外出仓工作台契约（仓库视角：无价格/金额字段）。 */
public final class OutboundContracts {

    private OutboundContracts() {
    }

    /** 待出仓任务列表行（一张 OPEN 发料计划 = 一个任务）。 */
    public record OutboundTaskListItem(
            UUID planId,
            UUID orderId,
            String orderBillNo,
            String supplierName,
            LocalDate deliverDate,
            int lineCount,
            BigDecimal plannedQty,
            BigDecimal issuedQty,
            BigDecimal remainingQty,
            /** 未审出仓草稿（null = 尚未生成/已被处理）。 */
            UUID draftId,
            String draftBillNo,
            BigDecimal readyOutboundQty,
            int readyLineCount,
            int waitingPreparationCount,
            int blockedLineCount) {
    }

    /** Server-authoritative outbound line; parent fields are legacy compatibility only. */
    public record OutboundPlanLine(
            UUID planItemId,
            UUID orderItemId,
            UUID parentGoodsId,
            UUID parentColorId,
            String parentGoodsCode,
            String parentGoodsName,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            String goodsStockPlace,
            UUID colorId,
            String colorName,
            UUID unitId,
            String unitName,
            BigDecimal unitRate,
            BigDecimal bomUnitQty,
            BigDecimal plannedQty,
            BigDecimal issuedQty,
            BigDecimal draftReservedQty,
            String flowMode,
            String preparationStatus,
            BigDecimal preparedQty,
            BigDecimal readyOutboundQty,
            BigDecimal remainingQty,
            UUID preparationAnalysisId,
            UUID preparationAnalysisItemId,
            String blocker,
            List<String> allowedActions) {
        public OutboundPlanLine {
            allowedActions = allowedActions == null ? List.of() : List.copyOf(allowedActions);
        }
    }

    /** 计划关联的出仓单（草稿/已审/红冲历史）。 */
    public record OutboundDraftRef(
            UUID issueId,
            String billNo,
            Short status,
            LocalDate billDate,
            String warehouseName,
            String approverName,
            BigDecimal totalQty) {
    }

    public record OutboundTaskDetail(
            UUID planId,
            UUID orderId,
            String orderBillNo,
            String status,
            UUID supplierId,
            String supplierName,
            LocalDate deliverDate,
            String closeReason,
            List<OutboundPlanLine> lines,
            List<OutboundDraftRef> drafts) {
        public OutboundTaskDetail {
            lines = List.copyOf(lines);
            drafts = List.copyOf(drafts);
        }
    }
}
