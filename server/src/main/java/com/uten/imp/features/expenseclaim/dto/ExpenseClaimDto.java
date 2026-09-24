package com.uten.imp.features.expenseclaim.dto;

import com.uten.imp.features.attachment.dto.AttachmentDto;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 报销单 DTO。列表/详情共用：invoices/events/attachments 仅详情接口填充，
 * 列表与动作响应里为空集合（操作人姓名在所有形态都回填，供列表进度列显示）。
 */
public record ExpenseClaimDto(
        UUID id,
        String claimNo,
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
        Instant rejectedAt,
        Instant paidAt,
        String remark,
        String rejectReason,
        String approvedByName,
        String rejectedByName,
        String paidByName,
        LocalDate paymentDate,
        UUID paymentAccountId,
        String paymentAccountName,
        UUID paymentExpenseStyleId,
        String paymentExpenseStyleName,
        UUID financeExpenseId,
        List<AttachmentDto> attachments,
        List<ExpenseClaimInvoiceDto> invoices,
        List<ExpenseClaimEventDto> events, long version, UUID approvedBy, List<AttachmentDto> paymentProofs,
        String previousSubmissionSnapshot, String submissionSnapshot, boolean resubmission) {
}
