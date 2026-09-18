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
        long lockVersion,
        boolean zeroMaterial,
        boolean drawRequested,
        boolean canRequestDraw,
        boolean canSplitBatch,
        UUID sourceSegmentId,
        boolean splitReplaced,
        /** 持续生产(V595)：同车间直送子件分次到料、到一批投一批。 */
        boolean continuousSupply,
        /** 可按「部分开工 · 持续生产」开工(V595)：未被动过的等待物料段且至少一条子件可直送。 */
        boolean canStartContinuous,
        /** 已确认的开工路线(V599)：FULL_KIT/BATCH/CONTINUOUS；NULL=待车间确认。 */
        String startRoute) {
}
