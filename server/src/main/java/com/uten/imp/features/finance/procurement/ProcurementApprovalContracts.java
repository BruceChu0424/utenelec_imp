package com.uten.imp.features.finance.procurement;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
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

    /** 精确绑定一次待审 case，避免驳回重提后相同版本号误命中新 attempt。 */
    public record BatchDecisionItem(
            @NotNull UUID caseId,
            @NotNull @Min(1) Long expectedVersion) {
    }

    public record BatchApprovalRequest(
            @NotEmpty @Size(max = 100) List<@Valid BatchDecisionItem> items) {
    }

    public record BatchRejectionRequest(
            @NotEmpty @Size(max = 100) List<@Valid BatchDecisionItem> items,
            @NotBlank @Size(max = 1000) String reason) {
    }

    public record BatchDecisionResponse(
            int processed,
            List<FinanceApproval> decisions) {
        public BatchDecisionResponse {
            decisions = List.copyOf(decisions);
        }
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
