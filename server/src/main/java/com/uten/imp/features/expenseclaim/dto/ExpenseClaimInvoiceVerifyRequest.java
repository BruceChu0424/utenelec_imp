package com.uten.imp.features.expenseclaim.dto;
import jakarta.validation.constraints.*;
public record ExpenseClaimInvoiceVerifyRequest(@NotNull @PositiveOrZero Long expectedVersion,
        @NotBlank String result, @NotBlank @Size(max=500) String remark) {}
