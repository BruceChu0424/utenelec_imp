package com.uten.imp.features.stock.allocation.dto;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/** Positive settlement posting that can be selected for an exact reversal. */
public record ProductionMaterialSettlementSourceRow(
        UUID postingId,
        UUID eventId,
        UUID demandId,
        UUID executionSegmentId,
        String executionSegmentCode,
        UUID goodsId,
        String goodsCode,
        String goodsName,
        UUID colorId,
        String colorName,
        String settlementType,
        BigDecimal postedQtyBase,
        BigDecimal reversedQtyBase,
        BigDecimal reversibleQtyBase,
        String reason,
        OffsetDateTime createdAt,
        UUID createdBy) {
}
