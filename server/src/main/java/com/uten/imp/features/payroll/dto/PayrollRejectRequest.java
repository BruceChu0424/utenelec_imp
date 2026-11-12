package com.uten.imp.features.payroll.dto;

import jakarta.validation.constraints.Size;

public record PayrollRejectRequest(
        @Size(max = 1000) String reason
) {
}
