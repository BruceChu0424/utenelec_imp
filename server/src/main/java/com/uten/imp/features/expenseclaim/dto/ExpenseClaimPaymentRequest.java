package com.uten.imp.features.expenseclaim.dto;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PastOrPresent;

import java.time.LocalDate;
import java.util.UUID;

public record ExpenseClaimPaymentRequest(
        @NotNull UUID accountId,
        @NotNull UUID expenseStyleId,
        @NotNull @PastOrPresent LocalDate paymentDate
) {
}
