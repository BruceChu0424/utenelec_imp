package com.uten.imp.features.payroll.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record PayrollRejectRequest(
        @NotBlank @Size(max = 1000) String reason
) {
}
