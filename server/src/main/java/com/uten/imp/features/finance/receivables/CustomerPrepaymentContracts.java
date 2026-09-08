package com.uten.imp.features.finance.receivables;

import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Stable HTTP contracts for finance-owned customer advances. Money is rendered as decimal text. */
public final class CustomerPrepaymentContracts {
    private CustomerPrepaymentContracts() {}

    public record Target(
            @NotNull UUID receivableLedgerId,
            @NotNull UUID salesOrderId,
            @NotNull @DecimalMin(value = "0.0001") BigDecimal amountOriginal) {}

    public record ApplyRequest(
            @NotBlank @Size(max = 120) String idempotencyKey,
            @NotNull UUID sourceLedgerId,
            @NotEmpty @Size(max = 500) List<@Valid Target> targets,
            @NotBlank @Size(max = 2000) String reason) {}

    public record ReverseRequest(
            @NotNull Long expectedVersion,
            @NotBlank @Size(max = 2000) String reason) {}

    public record Allocation(
            UUID id,
            int lineSequence,
            UUID sourceLedgerId,
            UUID receivableLedgerId,
            UUID targetSourceRefId,
            UUID salesOrderId,
            String amountOriginal,
            String sourceAmountLocal,
            String targetAmountLocal,
            String exchangeDifferenceLocal,
            String sourceRate,
            String targetRate,
            String sourceBalanceBeforeOriginal,
            String sourceBalanceAfterOriginal,
            String targetBalanceBeforeOriginal,
            String targetBalanceAfterOriginal,
            String status) {}

    public record BatchDetail(
            UUID batchId,
            long rowVersion,
            String status,
            LocalDate effectiveDate,
            UUID clientId,
            UUID currencyId,
            String reason,
            OffsetDateTime appliedAt,
            OffsetDateTime reversedAt,
            List<Allocation> allocations) {}

    public record PrepaymentItem(
            UUID ledgerId,
            UUID receiptId,
            String billNo,
            LocalDate billDate,
            UUID salesOrderId,
            UUID clientId,
            String clientName,
            UUID currencyId,
            String currencyCode,
            String currencyName,
            String exchangeRate,
            String receivedOriginal,
            String receivedLocal,
            String appliedOriginal,
            String appliedSourceBookLocal,
            String availableOriginal,
            String availableLocal,
            OffsetDateTime updatedAt) {}

    public record PrepaymentListSummary(
            String receivedOriginal,
            String receivedLocal,
            String appliedOriginal,
            String appliedSourceBookLocal,
            String availableOriginal,
            String availableLocal) {}

    public record PrepaymentPage(
            PrepaymentListSummary summary,
            List<PrepaymentItem> items,
            int page,
            int size,
            long total,
            int totalPages) {}

    public record UnallocatedReceiptLine(
            UUID receiptLineId,
            UUID receiptId,
            String billNo,
            LocalDate billDate,
            String amountOriginal,
            String amountLocal,
            String reason) {}

    public record SalesOrderMoneySummary(
            UUID salesOrderId,
            String orderBillNo,
            UUID clientId,
            UUID currencyId,
            String currencyCode,
            String orderTotalOriginal,
            String orderTotalLocal,
            String formalArOriginal,
            String formalArLocal,
            String cashReceivedOriginal,
            String cashReceivedLocal,
            String writeOffOriginal,
            String writeOffLocal,
            String prepaymentReceivedOriginal,
            String prepaymentReceivedLocal,
            String prepaymentAppliedOriginal,
            String prepaymentAppliedSourceBookLocal,
            String prepaymentAppliedTargetBookLocal,
            String prepaymentExchangeDifferenceLocal,
            String prepaymentAvailableOriginal,
            String prepaymentAvailableLocal,
            String arOutstandingOriginal,
            String arOutstandingLocal,
            String unrecognizedOrderOriginal,
            String unrecognizedOrderLocal,
            String plannedRemainingOriginal,
            String overpaidOriginal,
            boolean hasUnallocated,
            List<UnallocatedReceiptLine> unallocatedReceiptLines,
            List<String> warnings,
            String returnCreditOriginal,
            String returnCreditLocal,
            String unusedReturnCreditOriginal,
            String unusedReturnCreditLocal,
            String netReceivableOriginal,
            String netReceivableLocal,
            String customerPendingBalanceOriginal,
            String customerPendingBalanceLocal,
            boolean positionComplete,
            long unresolvedPositionCount) {}
}
