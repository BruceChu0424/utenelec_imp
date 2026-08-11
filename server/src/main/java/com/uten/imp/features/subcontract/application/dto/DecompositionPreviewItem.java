package com.uten.imp.features.subcontract.application.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** Demand-only subcontract line exposed to the outsourcing decomposition screen. */
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
