package com.uten.imp.features.expenseclaim.dto;
import jakarta.validation.constraints.*;
public record ExpenseClaimSettingsDto(@NotBlank @Size(max=200) String companyName,
        @Size(max=20) String companyTaxNo, @Size(max=2000) String submissionGuide,
        boolean requireInvoice, @NotNull @PositiveOrZero Long version) {}
