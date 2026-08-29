package com.uten.imp.features.finance.payables;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** API records for frozen supplier monthly settlement statements. */
public final class SupplierSettlementContracts {
    private SupplierSettlementContracts() {}

    public record FreezeRequest(
            UUID supplierId,
            UUID currencyId,
            LocalDate periodStart,
            UUID settlementMethodId,
            LocalDate dueDate) {}

    public record ConfirmRequest(long expectedVersion, String reference, String note) {}
    public record DisputeRequest(long expectedVersion, String reason) {}
    public record ReverseRequest(long expectedVersion, String reason) {}

    public record BatchSummary(
            UUID id,
            String batchNo,
            UUID supplierId,
            String supplierCode,
            String supplierName,
            UUID currencyId,
            String currencyCode,
            String currencyName,
            String periodStart,
            String periodEnd,
            String dueDate,
            String status,
            String openingBalanceOriginal,
            String periodPostedOriginal,
            String periodPaidOriginal,
            String periodOffsetOriginal,
            String closingBalanceOriginal,
            String openingBalanceLocal,
            String periodPostedLocal,
            String periodPaidLocal,
            String periodOffsetLocal,
            String closingBalanceLocal,
            int lineCount,
            long version,
            String snapshotHash,
            String createdAt) {}

    public record BatchLine(
            UUID id,
            UUID ledgerId,
            String businessType,
            String openItemKind,
            String sourceDocType,
            UUID sourceDocId,
            String sourceDocNo,
            String billDate,
            String dueDate,
            String bookingRate,
            String openingBalanceOriginal,
            String periodPostedOriginal,
            String periodPaidOriginal,
            String periodOffsetOriginal,
            String closingBalanceOriginal,
            String openingBalanceLocal,
            String periodPostedLocal,
            String periodPaidLocal,
            String periodOffsetLocal,
            String closingBalanceLocal) {}

    public record BatchEvent(
            UUID id,
            String type,
            UUID actorUserId,
            String reason,
            String createdAt) {}

    public record BatchDetail(
            BatchSummary summary,
            List<BatchLine> lines,
            List<BatchEvent> events) {}

    public record BatchPage(
            List<BatchSummary> items,
            int page,
            int size,
            long total,
            int totalPages) {}
}
