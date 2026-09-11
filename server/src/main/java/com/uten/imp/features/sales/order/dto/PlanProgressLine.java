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
        /** 剩余未排量（V545：未交付 − 预留 − 未完工计划量，服务端派生；>0 即该行仍待排产）。 */
        BigDecimal unplannedQty,
        List<MaterialAnalysisProgress> materialAnalyses,
        List<PlanLink> links) {

    /**
     * Sales-safe pre-plan snapshot. A sales line can appear in more than one
     * analysis over its lifetime, so analyses remain child records.
     */
    public record MaterialAnalysisProgress(
            UUID analysisId,
            String status,
            OffsetDateTime analyzedAt,
            BigDecimal requestedQty,
            BigDecimal submittedQty,
            BigDecimal approvedQty,
            BigDecimal remainingQty,
            BigDecimal readyNowQty,
            BigDecimal readyByDateQty,
            LocalDate expectedReadyDate,
            List<SupplyActionProgress> supplyActions) {
    }

    /**
     * Downstream preparation status intentionally omits supplier, price,
     * document number and employee identities.
     */
    public record SupplyActionProgress(
            UUID actionId,
            String route,
            String status,
            BigDecimal allocatedQty,
            LocalDate needDate) {
    }

    /**
     * Formal production batch, including append-only analysis lifecycle
     * history when the legacy sales allocation link does not yet exist or was
     * reversed. allocationStatus is null for legacy non-analysis plans.
     */
    public record PlanLink(
            UUID planId,
            String planNo,
            Short planStatus,
            String allocationStatus,
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
