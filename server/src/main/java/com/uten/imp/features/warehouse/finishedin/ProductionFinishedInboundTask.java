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
        /** 一单多货品的身份摘要，每项形如「名称 (编号 · 颜色)」，多项以「、」连接。 */
        String goodsSummary,
        int lineCount,
        BigDecimal pendingQty,
        OffsetDateTime createdAt,
        boolean residualTask) {
}
