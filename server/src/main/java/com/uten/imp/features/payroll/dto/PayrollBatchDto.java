package com.uten.imp.features.payroll.dto;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

public record PayrollBatchDto(
        UUID id,
        int year,
        int month,
        UUID departmentId,
        String departmentName,
        String status,
        int headcount,
        BigDecimal grossIncome,
        BigDecimal totalDeduction,
        BigDecimal netIncome,
        List<PayrollSlipDto> slips,
        Instant createdAt,
        Instant submittedAt,
        Instant approvedAt,
        Instant publishedAt,
        String rejectReason
) {
}
