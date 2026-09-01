package com.uten.imp.features.finance.payables;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Public contract for the purchase/subcontract IQC rejection work queue. */
public final class ProcurementIqcRejectionContracts {
    private ProcurementIqcRejectionContracts() {
    }

    public record CaseItem(
            UUID id,
            String receiptType,
            UUID receiptId,
            UUID receiptItemId,
            UUID inspectionItemId,
            String receiptBillNo,
            String orderBillNo,
            UUID supplierId,
            String supplierName,
            String goodsCode,
            String goodsName,
            String failedBaseQty,
            String failedQty,
            String unitName,
            String failedAmountOriginal,
            String failedAmountLocal,
            String currencyCode,
            String status,
            long version,
            UUID ownerUserId,
            String returnReference,
            String returnDate,
            String returnNote,
            String returnedAt,
            String creditReference,
            String creditDate,
            String creditConfirmedAt,
            String closedNoCreditReason,
            String closedNoCreditAt,
            String financeExceptionCode,
            String financeExceptionMessage,
            String holdReason,
            List<String> allowedActions,
            boolean priceMasked) {
    }

    public record CasePage(
            List<CaseItem> items,
            int page,
            int size,
            long total,
            int totalPages) {
    }

    public record CaseCounts(
            long total,
            long pendingReturn,
            long returnRecorded,
            long creditConfirmed,
            long closedNoCredit,
            long financeException,
            long reversed) {
    }

    public record CaseEventItem(
            UUID id,
            String eventType,
            UUID actorUserId,
            UUID commandId,
            String reference,
            String eventDate,
            String reason,
            String createdAt) {
    }

    public record ReplacementAllocationItem(
            UUID id,
            String replacementReceiptType,
            UUID replacementReceiptId,
            UUID replacementReceiptItemId,
            String allocatedBaseQty,
            String allocatedQty,
            String allocatedAmountOriginal,
            String allocatedAmountLocal,
            String status,
            String createdAt,
            String reversedAt) {
    }

    public record CaseDetail(
            CaseItem caseItem,
            List<CaseEventItem> events,
            List<ReplacementAllocationItem> replacementAllocations) {
    }

    public record RecordReturnRequest(
            @Min(1) long expectedVersion,
            @NotNull UUID commandId,
            @NotBlank @Size(max = 200) String returnReference,
            @NotNull LocalDate returnDate,
            @NotBlank @Size(max = 2000) String returnNote) {
    }

    public record ConfirmCreditRequest(
            @Min(1) long expectedVersion,
            @NotNull UUID commandId,
            @NotBlank @Size(max = 200) String creditReference,
            @NotNull LocalDate creditDate,
            @NotBlank @Size(max = 2000) String reason) {
    }

    public record CloseNoCreditRequest(
            @Min(1) long expectedVersion,
            @NotNull UUID commandId,
            @NotBlank @Size(max = 2000) String reason) {
    }

    public record ReverseRequest(
            @Min(1) long expectedVersion,
            @NotNull UUID commandId,
            @NotBlank @Size(max = 2000) String reason) {
    }

    public record RetryFinanceProjectionRequest(
            @Min(1) long expectedVersion,
            @NotNull UUID commandId,
            @NotBlank @Size(max = 2000) String reason) {
    }
}
