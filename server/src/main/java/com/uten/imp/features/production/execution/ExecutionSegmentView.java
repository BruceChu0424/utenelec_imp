package com.uten.imp.features.production.execution;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** Reader-facing execution segment with material and reporting progress. */
public record ExecutionSegmentView(
        UUID id,
        UUID packageId,
        UUID planId,
        UUID sourcePlanItemId,
        Integer segmentNo,
        String segmentCode,
        UUID productGoodsId,
        String productCode,
        String productName,
        UUID productColorId,
        UUID productUnitId,
        BigDecimal plannedQty,
        BigDecimal reportedQty,
        BigDecimal remainingQty,
        String status,
        boolean autoPromoteWhenReady,
        UUID workshopDepartmentId,
        String workshopName,
        UUID teamDepartmentId,
        String teamName,
        UUID responsibleEmployeeId,
        String responsibleEmployeeName,
        LocalDate planBeginDate,
        LocalDate planEndDate,
        int materialKindCount,
        int shortageKindCount,
        boolean materialReady,
        int materialDemandCount,
        int fullyIssuedDemandCount,
        boolean materialIssued,
        BigDecimal fqcPendingQty,
        BigDecimal fqcPassedQty,
        BigDecimal fqcFailedQty,
        BigDecimal finishedInboundPendingQty,
        BigDecimal inboundQty,
        BigDecimal finishedInboundRejectedQty,
        BigDecimal ordinaryRemainingQty,
        BigDecimal fqcRecoveryAvailableQty,
        BigDecimal fqcReworkAvailableQty,
        BigDecimal fqcReplacementAvailableQty,
        BigDecimal fqcReplacementReadyQty,
        long lockVersion) {
}
