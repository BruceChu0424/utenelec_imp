package com.uten.imp.features.finance.accountbalance.dto;

import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotNull;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * One account's optimistic before-value and requested target balance.
 *
 * <p>{@code localDelta} is not an account-balance conversion. Account balances
 * always remain in the account currency. It is an explicit base-currency GL
 * adjustment supplied by finance only when a non-base-currency balance changes.
 * Base-currency and zero-delta rows may omit it.
 */
public record AccountBalanceAdjustmentItemRequest(
        @NotNull UUID accountId,
        @NotNull @Digits(integer = 14, fraction = 4) BigDecimal expectedBalance,
        @NotNull @Digits(integer = 14, fraction = 4) BigDecimal targetBalance,
        @Digits(integer = 14, fraction = 4) BigDecimal localDelta) {
}
