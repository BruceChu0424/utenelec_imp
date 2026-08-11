package com.uten.imp.features.warehouse.inbound.dto;

import java.math.BigDecimal;
import java.util.UUID;

/** 采购/委外收货待检冻结明细投影（IQC）。 */
public record ProcurementInspectionItemDto(
        UUID id,
        UUID receiptItemId,
        UUID goodsId,
        UUID colorId,
        UUID unitId,
        BigDecimal unitRate,
        BigDecimal receivedBaseQty,
        BigDecimal passedBaseQty,
        BigDecimal failedBaseQty,
        BigDecimal remainingBaseQty,
        String status) {
}
