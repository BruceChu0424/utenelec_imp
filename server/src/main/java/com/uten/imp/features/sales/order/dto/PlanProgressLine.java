package com.uten.imp.features.sales.order.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * 订单行排产进度（销售端看链路另一端）：订货/可发/已排/已产 + 关联生产计划溯源。
 * 草稿计划（合并排产预建 links）也会列出，状态由 planStatus 区分（0草稿 1已审）。
 */
public record PlanProgressLine(
        UUID orderItemId,
        Integer lineNo,
        String goodsCode,
        String goodsName,
        String spec,
        String colorName,
        String unitName,
        BigDecimal qty,
        BigDecimal reservedQty,
        BigDecimal plannedQty,
        BigDecimal producedQty,
        BigDecimal shippedQty,
        Short chainStatus,
        List<PlanLink> links) {

    /** 关联生产计划（plan_order_item_links 溯源）。 */
    public record PlanLink(
            UUID planId,
            String planNo,
            Short planStatus,
            boolean planClosed,
            LocalDate billDate,
            BigDecimal allocatedQty,
            BigDecimal producedQty,
            BigDecimal inboundQty,
            List<ExecutionSegmentProgress> executionSegments) {
    }

    /** Sales-safe execution detail; no material, cost or supplier fields. */
    public record ExecutionSegmentProgress(
            UUID executionSegmentId,
            String segmentCode,
            String status,
            BigDecimal allocatedQty,
            BigDecimal reportedQty,
            BigDecimal inboundQty,
            String workshopName,
            String teamName,
            LocalDate planBeginDate,
            LocalDate planEndDate,
            OffsetDateTime actualStartAt,
            boolean delayed,
            String delayReason) {
    }
}
