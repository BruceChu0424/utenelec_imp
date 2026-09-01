package com.uten.imp.features.warehouse.finishedin;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

/** Warehouse-owned projection for production FINISHED_IN drafts awaiting count. */
public record ProductionFinishedInboundTask(
        String taskStage,
        UUID taskId,
        UUID reportId,
        UUID documentId,
        String documentNo,
        LocalDate documentDate,
        UUID warehouseId,
        String warehouseName,
        UUID planId,
        String planNo,
        String reportNos,
        String goodsSummary,
        int lineCount,
        BigDecimal pendingQty,
        OffsetDateTime createdAt,
        boolean residualTask) {
}
