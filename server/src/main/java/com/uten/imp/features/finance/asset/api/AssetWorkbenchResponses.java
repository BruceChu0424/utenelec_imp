package com.uten.imp.features.finance.asset.api;

import com.fasterxml.jackson.annotation.JsonFormat;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/** Stable typed response records; database rows never leak as positional arrays or maps. */
public final class AssetWorkbenchResponses {

    private AssetWorkbenchResponses() {}

    public record Overview(
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal originalValue,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal netBookValue,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal deferredBalance,
            long pendingCount,
            long exceptionCount,
            long pendingOrExceptionCount,
            String asOf,
            boolean policyReady,
            List<String> missingPolicyItems,
            boolean postedWorkflowsEnabled,
            List<String> operationalBlockers) {}

    public record Summary(
            UUID id,
            String objectType,
            String code,
            String name,
            String status,
            String approvalStatus,
            UUID categoryId,
            String categoryName,
            UUID departmentId,
            String departmentName,
            UUID custodianId,
            String custodianName,
            String location,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal originalValue,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal totalAmount,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal netBookValue,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal remainingAmount,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal salvageRate,
            Integer usefulMonths,
            String startPeriod,
            LocalDate readyForUseDate,
            LocalDate benefitStartDate,
            String operatingStatus,
            String sourceType,
            String sourceRef,
            String remark,
            long version,
            Set<String> allowedActions,
            LocalDate acquisitionDate,
            LocalDate acceptanceDate,
            String serialNumber,
            String assetTag,
            String costCenterCode,
            LocalDate benefitEndDate,
            UUID sourceId,
            String sourceLineRef,
            LocalDate sourceDocumentDate,
            UUID responsibleEmployeeId) {}

    public record Balance(
            String bookType,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal originalValue,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal residualAmount,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal accumulatedAmount,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal netValue,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal monthlyAmount,
            String startPeriod,
            String status) {}

    public record ScheduleLine(
            UUID id,
            int sequence,
            String period,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal openingBalance,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal amount,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal accumulatedAmount,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal closingBalance,
            String status,
            String voucherNo) {}

    public record ApprovalStep(
            UUID id,
            String action,
            String status,
            UUID actorId,
            String actorName,
            String comment,
            Instant at) {}

    public record Event(
            UUID id,
            String eventType,
            String title,
            String description,
            UUID actorId,
            String operatorName,
            LocalDate effectiveDate,
            Instant at) {}

    public record Detail(
            Summary summary,
            List<Balance> balances,
            List<Balance> books,
            List<ScheduleLine> schedule,
            List<ApprovalStep> approvalSteps,
            List<Event> events,
            List<String> voucherNumbers,
            List<String> documentReferences,
            Set<String> allowedActions) {}

    public record WorkflowResult(UUID id, String status, String approvalStatus, long version,
                                 Set<String> allowedActions) {}

    public record PostingException(
            String code,
            String severity,
            String message,
            UUID objectId) {}

    public record PostingLine(
            UUID id,
            UUID objectId,
            String objectType,
            String code,
            String name,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal openingBalance,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal amount,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal closingBalance,
            String status,
            String message) {}

    public record PostingRun(
            UUID id,
            String runType,
            String bookType,
            String period,
            String status,
            String token,
            int itemCount,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal totalAmount,
            List<PostingException> exceptions,
            List<PostingLine> lines,
            String voucherNo,
            UUID reversalOfRunId,
            long version,
            Instant createdAt,
            Set<String> allowedActions) {}

    public record Period(
            String period,
            String status,
            boolean closed,
            boolean depreciationPosted,
            boolean amortizationPosted,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal reconciliationDifference,
            String reason,
            Instant closedAt,
            long version,
            Set<String> allowedActions) {}
}
