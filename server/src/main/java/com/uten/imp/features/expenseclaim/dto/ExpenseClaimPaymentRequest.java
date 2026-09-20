package com.uten.imp.features.expenseclaim.dto;

import jakarta.validation.constraints.NotNull;

import java.time.LocalDate;
import java.util.UUID;

public record ExpenseClaimPaymentRequest(
        @NotNull UUID accountId,
        @NotNull UUID expenseStyleId,
        @NotNull LocalDate paymentDate, Long expectedVersion
) {
    public ExpenseClaimPaymentRequest(UUID accountId, UUID expenseStyleId, LocalDate paymentDate) { this(accountId,expenseStyleId,paymentDate,null); }
}
