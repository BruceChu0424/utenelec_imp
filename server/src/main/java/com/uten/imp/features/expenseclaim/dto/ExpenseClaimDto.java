package com.uten.imp.features.expenseclaim.dto;

import com.uten.imp.features.attachment.dto.AttachmentDto;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

public record ExpenseClaimDto(
        UUID id,
        UUID applicantId,
        String applicantName,
        UUID departmentId,
        String departmentName,
        String title,
        List<ExpenseClaimItemDto> items,
        BigDecimal totalAmount,
        String status,
        Instant createdAt,
        Instant submittedAt,
        Instant approvedAt,
        Instant paidAt,
        String remark,
        String rejectReason,
        List<AttachmentDto> attachments
) {
}
