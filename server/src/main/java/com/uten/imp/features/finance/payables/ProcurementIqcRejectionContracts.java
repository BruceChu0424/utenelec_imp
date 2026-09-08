package com.uten.imp.features.finance.payables;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;

import java.math.BigDecimal;
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
            List<ReplacementAllocationItem> replacementAllocations,
            ResolutionItem resolution,
            List<CreditResolutionItem> creditDocuments,
            List<CreditSourceItem> creditSources) {
        public CaseDetail(CaseItem caseItem,List<CaseEventItem> events,List<ReplacementAllocationItem> replacementAllocations){
            this(caseItem,events,replacementAllocations,null,List.of(),List.of());
        }
    }

    public record CreditSourceItem(UUID sourceApLedgerId,String sourceBillNo,
            String amountOriginal,String amountLocal,String creditedAmountOriginal,
            String remainingAmountOriginal,List<CreditCaseChoice> cases) {}

    public record CreditCaseChoice(UUID caseId,long version,String receiptBillNo,
            String goodsName,String creditableBaseQty,String baseUnitName) {}

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
            @NotBlank @Size(max = 2000) String reason,
            @DecimalMin(value = "0", inclusive = false) @Digits(integer = 14, fraction = 4)
            BigDecimal baseQty,
            BigDecimal actualAmountOriginal,
            UUID sourceApLedgerId,
            @jakarta.validation.Valid @Size(max = 100) List<ActualCreditAllocation> allocations,
            @jakarta.validation.constraints.Pattern(regexp="[0-9a-f]{64}") String expectedBookAllocationHash) {
        public ConfirmCreditRequest(long expectedVersion, UUID commandId,
                String creditReference, LocalDate creditDate, String reason) {
            this(expectedVersion, commandId, creditReference, creditDate, reason, null,null,null,null,null);
        }

        public ConfirmCreditRequest(long expectedVersion, UUID commandId,
                String creditReference, LocalDate creditDate, String reason,BigDecimal baseQty) {
            this(expectedVersion,commandId,creditReference,creditDate,reason,baseQty,null,null,null,null);
        }
        public ConfirmCreditRequest(long expectedVersion,UUID commandId,String creditReference,LocalDate creditDate,
                String reason,BigDecimal baseQty,BigDecimal actualAmountOriginal,UUID sourceApLedgerId,List<ActualCreditAllocation> allocations){
            this(expectedVersion,commandId,creditReference,creditDate,reason,baseQty,actualAmountOriginal,sourceApLedgerId,allocations,null);
        }
    }

    public record CreditBookPreview(String bookAllocationHash,String amountOriginal,String amountLocal,
            String offsetOriginal,String offsetLocal,String creditRemainingOriginal,String creditRemainingLocal,
            String sourceBeforeOriginal,String sourceBeforeLocal,String sourceAfterOriginal,String sourceAfterLocal,
            List<CreditCaseBookItem> caseAllocations) {}
    public record CreditCaseBookItem(UUID caseId,String baseQty,String amountOriginal,String amountLocal,
            String beforeOriginal,String beforeLocal,String afterOriginal,String afterLocal) {}

    public record ActualCreditAllocation(
            @NotNull UUID caseId,
            @Min(1) long expectedVersion,
            @NotNull @DecimalMin(value="0",inclusive=false) @Digits(integer=14,fraction=4) BigDecimal baseQty,
            @NotNull BigDecimal amountOriginal) {
    }

    public record CloseNoCreditRequest(
            @Min(1) long expectedVersion,
            @NotNull UUID commandId,
            @NotBlank @Size(max = 2000) String reason) {
    }

    public record ReverseRequest(
            @Min(1) long expectedVersion,
            @NotNull UUID commandId,
            @NotBlank @Size(max = 2000) String reason,
            UUID creditDocumentId) {
        public ReverseRequest(long expectedVersion, UUID commandId, String reason) {
            this(expectedVersion, commandId, reason, null);
        }
    }

    public record ResolutionItem(
            String baseUnitName,
            String creditableBaseQty,
            String replacementPendingBaseQty,
            String replacementStockedBaseQty,
            String creditedBaseQty,
            String unresolvedBaseQty,
            String unresolvedAmountOriginal,
            String unresolvedAmountLocal,
            String resolutionState,
            boolean legacyUnclassified) {
    }

    public record ConsiderationItem(
            UUID id,
            UUID replacementAllocationId,
            UUID replacementReceiptId,
            UUID replacementReceiptItemId,
            String billingMode,
            String baseQty,
            String nominalAmountOriginal,
            String nominalAmountLocal,
            String payableAmountOriginal,
            String payableAmountLocal,
            UUID fundingSliceId,
            UUID rootFailureCaseId,
            UUID creditDocumentId,
            String status) {
    }

    public record CreditResolutionItem(
            UUID creditDocumentId,
            String baseQty,
            String amountOriginal,
            String amountLocal,
            String creditReference,
            String creditDate,
            String status,
            boolean canReverse,
            List<CreditCaseBookItem> caseAllocations) {
    }

    public record RetryFinanceProjectionRequest(
            @Min(1) long expectedVersion,
            @NotNull UUID commandId,
            @NotBlank @Size(max = 2000) String reason) {
    }
}
