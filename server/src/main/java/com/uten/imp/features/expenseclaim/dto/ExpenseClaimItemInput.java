package com.uten.imp.features.expenseclaim.dto;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PastOrPresent;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;

public record ExpenseClaimItemInput(
        @NotBlank String category,
        @NotNull @DecimalMin(value = "0.00", inclusive = false)
        @Digits(integer = 16, fraction = 2) BigDecimal amount,
        @NotNull @PastOrPresent LocalDate date,
        @Size(max = 1000) String description
) {
}
