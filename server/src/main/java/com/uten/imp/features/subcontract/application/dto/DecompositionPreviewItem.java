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
        String sourcePlanNo,
        /**
         * ADR-156: 现有直属物料够做的套数(所选申请按需求日期先后共用公共库存, 前面的先分)。
         * 单测手工构造服务时为 null。
         */
        BigDecimal kitQty,
        /** ADR-156: 这次能下单的数量 = MIN(剩余, 够做的套数); 0 = 等物料齐套, 不预填这一行。 */
        BigDecimal orderableQty) {
}
