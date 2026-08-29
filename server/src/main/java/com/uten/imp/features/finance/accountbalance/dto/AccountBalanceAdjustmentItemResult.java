package com.uten.imp.features.finance.accountbalance.dto;

import java.math.BigDecimal;
import java.util.UUID;

/** Immutable account-currency balance evidence plus separately governed GL amount. */
public record AccountBalanceAdjustmentItemResult(
        UUID id,
        UUID accountId,
        String accountCode,
        String accountName,
        UUID currencyId,
        String currencyCode,
        String currencyName,
        BigDecimal exchangeRate,
        BigDecimal expectedBalance,
        BigDecimal targetBalance,
        BigDecimal delta,
        BigDecimal deltaLocal,
        String localAmountBasis,
        String exchangeRateText,
        String expectedBalanceText,
        String targetBalanceText,
        String deltaText,
        String deltaLocalText,
        boolean verified) {
}
