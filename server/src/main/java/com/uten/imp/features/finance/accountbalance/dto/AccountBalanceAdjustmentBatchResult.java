package com.uten.imp.features.finance.accountbalance.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Posted immutable batch returned both on first execution and idempotent replay. */
public record AccountBalanceAdjustmentBatchResult(
        UUID id,
        String batchNo,
        String scope,
        LocalDate effectiveDate,
        String reason,
        int itemCount,
        int changedCount,
        BigDecimal totalIncreaseLocal,
        BigDecimal totalDecreaseLocal,
        String totalIncreaseLocalText,
        String totalDecreaseLocalText,
        UUID actorId,
        OffsetDateTime createdAt,
        List<AccountBalanceAdjustmentItemResult> items) {
}
