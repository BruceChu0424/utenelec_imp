package com.uten.imp.features.finance.procurement;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public final class ProcurementApprovalContracts {

    private ProcurementApprovalContracts() {
    }

    public record FinanceApproval(
            UUID caseId,
            String status,
            int attempt,
            long version,
            UUID assigneeUserId,
            UUID assigneeEmployeeId,
            String assigneeName,
            String rejectionReason,
            OffsetDateTime submittedAt,
            List<String> allowedActions) {
        public FinanceApproval {
            allowedActions = List.copyOf(allowedActions);
        }
    }

    public record ApprovalDecisionRequest(
            @NotNull @Min(1) Long expectedVersion) {
    }

    public record RejectionDecisionRequest(
            @NotNull @Min(1) Long expectedVersion,
            @NotBlank @Size(max = 1000) String reason) {
    }

    public record ApprovalTask(
            UUID caseId,
            String orderType,
            UUID orderId,
            String billNo,
            BigDecimal amount,
            String supplierName,
            String warehouseName,
            LocalDate expectedDate,
            int attempt,
            long version,
            UUID submittedByEmployeeId,
            String submittedByName,
            OffsetDateTime submittedAt,
            List<String> allowedActions) {
    }
}
