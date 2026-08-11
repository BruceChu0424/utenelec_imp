package com.uten.imp.features.payroll.dto;

import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotNull;

import java.util.UUID;

public record PayrollBatchCreateRequest(
        @Min(2000) @Max(2200) int year,
        @Min(1) @Max(12) int month,
        UUID departmentId,
        @NotNull Boolean includeOvertime,
        @NotNull Boolean includeBonus,
        @NotNull Boolean includeSocialInsurance,
        @NotNull Boolean includeTax
) {
}
