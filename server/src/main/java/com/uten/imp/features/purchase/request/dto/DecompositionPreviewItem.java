package com.uten.imp.features.purchase.request.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** Demand-only purchase line exposed to the procurement decomposition screen. */
public record DecompositionPreviewItem(
        UUID sourceDocumentId,
        String sourceDocumentNo,
        UUID sourceItemId,
        UUID goodsId,
        UUID colorId,
        UUID unitId,
        BigDecimal unitRate,
        BigDecimal requestedQty,
        BigDecimal orderedQty,
        BigDecimal pendingQty,
        BigDecimal remainingQty,
        LocalDate needDate,
        UUID warehouseId,
        String sourcePlanNo) {
}
