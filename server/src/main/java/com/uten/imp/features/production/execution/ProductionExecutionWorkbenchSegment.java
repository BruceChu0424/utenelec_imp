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
        /** 持续生产：仓库料及同车间直送料分次投入，同一张工单只开一次工。 */
        boolean continuousSupply,
        /** 只剩线边仓直送料没出库(V595)：不用去领料，开工时就地自动出库，按「可开工」呈现。 */
        boolean pendingLineSideOnly,
        /** 已确认的开工路线(V599)：FULL_KIT/BATCH/CONTINUOUS；NULL=待车间确认。 */
        String startRoute,
        /** 待确认生产路线(V599)：等待物料且尚未选路，「下一步」首条=确认生产路线。 */
        boolean canConfirmRoute,
        /** 开工前且尚无实领或报工，可在保留已有备料事实的前提下调整路线。 */
        boolean routeChangeable,
        /** 存在正式物料需求，允许选择持续生产；来源可以为仓库、直送或混合。 */
        boolean routeContinuousEligible) {
}
