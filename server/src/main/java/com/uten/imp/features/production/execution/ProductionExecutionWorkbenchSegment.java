package com.uten.imp.features.production.execution;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** Exact work order with separate production, quality and warehouse facts. */
public record ProductionExecutionWorkbenchSegment(
        UUID segmentId,
        UUID planId,
        String planNo,
        String segmentCode,
        String salesOrderNos,
        UUID workshopDepartmentId,
        String workshopName,
        String responsibleEmployeeName,
        String productCode,
        String productName,
        String productColorName,
        String productUnitName,
        BigDecimal plannedQty,
        BigDecimal reportedQty,
        BigDecimal remainingReportQty,
        BigDecimal fqcPendingQty,
        BigDecimal fqcPassedQty,
        BigDecimal fqcFailedQty,
        BigDecimal finishedInboundPendingQty,
        BigDecimal inboundQty,
        String segmentStatus,
        String materialStatus,
        String preparationStatus,
        boolean materialReady,
        boolean warehouseReady,
        boolean issued,
        boolean canDispatch,
        boolean canStart,
        boolean canReport,
        boolean canBatchReport,
        String blockedReason,
        LocalDate planBeginDate,
        LocalDate planEndDate,
        long lockVersion,
        boolean zeroMaterial,
        boolean canRecheckMaterial,
        boolean hasMaterialActivity,
        boolean hasUnregisteredMaterial,
        boolean drawRequested,
        boolean canRequestDraw,
        boolean canSplitBatch,
        UUID sourceSegmentId,
        boolean splitReplaced,
        boolean hasSharedMaterialActivity,
        boolean hasPendingReturn,
        boolean hasAvailableMaterial,
        /** 持续生产(V595)：同车间直送子件分次到料、到一批投一批，同一张工单只开一次工。 */
        boolean continuousSupply,
        /** 可按「部分开工 · 持续生产」开工(V595)。 */
        boolean canStartContinuous,
        /** 只剩线边仓直送料没出库(V595)：不用去领料，开工时就地自动出库，按「可开工」呈现。 */
        boolean pendingLineSideOnly,
        /** 已确认的开工路线(V599)：FULL_KIT/BATCH/CONTINUOUS；NULL=待车间确认。 */
        String startRoute,
        /** 待确认生产路线(V599)：等待物料且尚未选路，「下一步」首条=确认生产路线。 */
        boolean canConfirmRoute,
        /** 可重新确认生产路线(V599)：WAITING 且未动过(无领料单/报工/供给钉/预留)。 */
        boolean routeChangeable,
        /** 存在可由本车间直送供给的子件(V599)：持续生产路线的候选项。 */
        boolean routeContinuousEligible) {
}
