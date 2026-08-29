package com.uten.imp.features.finance.accountbalance.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.time.LocalDate;
import java.util.List;

/** Atomic FULL or SELECTED account-balance verification request. */
public record AccountBalanceAdjustmentBatchRequest(
        @NotBlank @Pattern(regexp = "FULL|SELECTED") String scope,
        @NotNull LocalDate effectiveDate,
        @NotBlank @Size(max = 500) String reason,
        @NotBlank @Size(min = 8, max = 128)
        @Pattern(regexp = "[A-Za-z0-9._:-]+") String idempotencyKey,
        @NotEmpty @Size(max = 2000)
        List<@Valid AccountBalanceAdjustmentItemRequest> items) {
}
