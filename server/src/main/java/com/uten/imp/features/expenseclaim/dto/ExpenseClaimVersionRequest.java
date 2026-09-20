package com.uten.imp.features.expenseclaim.dto;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;
public record ExpenseClaimVersionRequest(@NotNull @PositiveOrZero Long expectedVersion) {}
