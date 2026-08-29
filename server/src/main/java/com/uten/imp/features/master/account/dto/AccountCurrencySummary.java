package com.uten.imp.features.master.account.dto;

import java.math.BigDecimal;
import java.util.UUID;

/** Account totals within one currency. Amounts from different rows must never be added directly. */
public record AccountCurrencySummary(
        UUID currencyId,
        String currencyCode,
        String currencyName,
        long accountCount,
        long activeAccountCount,
        BigDecimal balanceTotal,
        String balanceTotalText,
        long warningCount,
        long negativeCount) {
}
