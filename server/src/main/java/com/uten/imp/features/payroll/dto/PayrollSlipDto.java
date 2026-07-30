package com.uten.imp.features.payroll.dto;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

public record PayrollSlipDto(
        UUID id,
        UUID employeeId,
        String employeeName,
        String employeeCode,
        int year,
        int month,
        List<PayrollItemDto> items,
        BigDecimal grossIncome,
        BigDecimal totalDeduction,
        BigDecimal netIncome,
        String status,
        Instant publishedAt,
        Instant viewedAt,
        Instant downloadedAt,
        String remark
) {
}
