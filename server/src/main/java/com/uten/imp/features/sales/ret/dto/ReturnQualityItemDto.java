package com.uten.imp.features.sales.ret.dto;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/** Current quality-quarantine projection for one sales-return line. */
public record ReturnQualityItemDto(
        UUID id,
        UUID returnId,
        UUID returnItemId,
        UUID warehouseId,
        UUID goodsId,
        UUID colorId,
        UUID unitId,
        BigDecimal unitRate,
        BigDecimal receivedBaseQty,
        BigDecimal releasedBaseQty,
        BigDecimal scrappedBaseQty,
        BigDecimal reworkBaseQty,
        BigDecimal remainingBaseQty,
        String status,
        OffsetDateTime receivedAt,
        OffsetDateTime updatedAt) {
}
