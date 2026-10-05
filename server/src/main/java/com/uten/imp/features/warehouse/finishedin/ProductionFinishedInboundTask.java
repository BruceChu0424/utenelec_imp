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
        /** 行数 = 实物交接批数(ADR-148)：同一产出批次送入仓库的各份算一行。 */
        int lineCount,
        BigDecimal pendingQty,
        OffsetDateTime createdAt,
        boolean residualTask,
        /** 其中计划公共备货数量(服务端合计)。 */
        BigDecimal publicQty,
        /** 其中实际超产数量(服务端合计)。 */
        BigDecimal actualSurplusQty,
        /** 「其中实际超产 N」；没有实际超产时为空。 */
        String actualSurplusNote) {
}
