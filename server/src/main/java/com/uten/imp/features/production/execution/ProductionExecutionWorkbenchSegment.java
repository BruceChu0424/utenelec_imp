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
        long lockVersion) {
}
