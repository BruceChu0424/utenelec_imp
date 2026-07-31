package com.uten.imp.features.stock.dto;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

/** 授权库存余额调整结果，以及可追溯的盘点单记录。 */
public record StockBalanceAdjustmentResult(
        UUID documentId,
        String billNo,
        BigDecimal beforeQty,
        BigDecimal afterQty,
        BigDecimal deltaQty,
        UUID adjustedByEmployeeId,
        String adjustedByName,
        Instant adjustedAt) {
}
