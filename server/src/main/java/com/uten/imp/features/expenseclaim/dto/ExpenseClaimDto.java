package com.uten.imp.features.expenseclaim.dto;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

public record ExpenseClaimDto(
        UUID id,
        UUID applicantId,
        String applicantName,
        String title,
        List<ExpenseClaimItemDto> items,
        BigDecimal totalAmount,
        String status,
        Instant createdAt,
        Instant submittedAt,
        Instant approvedAt,
        Instant paidAt,
        String remark,
        String rejectReason
) {
}
