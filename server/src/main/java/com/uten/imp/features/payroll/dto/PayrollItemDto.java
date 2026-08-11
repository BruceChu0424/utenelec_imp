package com.uten.imp.features.payroll.dto;

import java.math.BigDecimal;

public record PayrollItemDto(
        String name,
        BigDecimal amount,
        String type,
        String description
) {
}
