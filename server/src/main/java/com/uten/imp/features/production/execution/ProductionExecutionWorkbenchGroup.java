package com.uten.imp.features.production.execution;

import java.time.LocalDate;
import java.util.UUID;

/** One bounded preview row per outer analysis, with a legacy root-plan fallback. */
public record ProductionExecutionWorkbenchGroup(
        String rootType,
        UUID rootId,
        String rootLabel,
        String status,
        String salesOrderPreview,
        int salesOrderCount,
        boolean salesOrderHasMore,
        String workOrderPreview,
        int workOrderCount,
        boolean workOrderHasMore,
        String workshopPreview,
        int workshopCount,
        boolean workshopHasMore,
        String productCodePreview,
        String productNamePreview,
        String productColorPreview,
        int productCount,
        boolean productHasMore,
        String quantitySummary,
        boolean mixedUnits,
        int executionUnitCount,
        boolean executionUnitHasMore,
        int planCount,
        int segmentCount,
        int waitingCount,
        int readyCount,
        int dispatchedCount,
        int inProgressCount,
        int completedCount,
        int materialReadyCount,
        int warehouseReadyCount,
        int issuedCount,
        int reportableCount,
        int fqcPendingCount,
        int finishedInboundPendingCount,
        boolean mine,
        LocalDate earliestBeginDate,
        LocalDate latestEndDate) {
}
