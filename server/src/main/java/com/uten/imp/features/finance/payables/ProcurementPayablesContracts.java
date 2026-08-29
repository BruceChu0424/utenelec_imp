package com.uten.imp.features.finance.payables;

import java.util.List;
import java.util.UUID;

/** API records for the purchase/subcontract payable workbench. */
public final class ProcurementPayablesContracts {
    private ProcurementPayablesContracts() {}

    public record Summary(
            String payableLocal,
            String paidLocal,
            String settledBookLocal,
            String exchangeDifferenceLocal,
            String offsetLocal,
            String outstandingLocal,
            String overdueLocal,
            String dueThisMonthLocal,
            String creditLocal,
            String prepaymentLocal,
            long pendingLossCases) {}

    public record Item(
            UUID id,
            String businessType,
            String openItemKind,
            String sourceDocType,
            UUID sourceDocId,
            String sourceDocNo,
            UUID supplierId,
            String supplierCode,
            String supplierName,
            String billDate,
            String dueDate,
            String settlementPeriod,
            UUID settlementMethodId,
            String settlementMethodCode,
            String settlementMethodName,
            Integer creditDays,
            UUID currencyId,
            String currencyCode,
            String currencyName,
            String bookingRate,
            String grossOriginal,
            String grossLocal,
            String paidOriginal,
            String paidLocal,
            String offsetOriginal,
            String offsetLocal,
            String outstandingOriginal,
            String outstandingLocal,
            String status,
            int overdueDays,
            String remark) {}

    public record Page(
            Summary summary,
            List<Item> items,
            int page,
            int size,
            long total,
            int totalPages) {}

    public record PaymentAllocation(
            UUID paymentId,
            String paymentNo,
            String paymentDate,
            String cashOriginal,
            String cashLocal,
            String appliedLocal,
            String exchangeDifference,
            short status) {}

    public record OffsetAllocation(
            UUID allocationId,
            UUID sourceLedgerId,
            String sourceBillNo,
            String amountOriginal,
            String sourceAmountLocal,
            String targetAmountLocal,
            String effectiveDate,
            String status,
            String reason) {}

    public record Detail(
            Item item,
            List<PaymentAllocation> paymentAllocations,
            List<OffsetAllocation> offsetAllocations) {}

    public record PaymentPreviewRequest(List<UUID> payableIds) {}

    public record PaymentPreview(
            boolean eligible,
            String reason,
            UUID supplierId,
            String supplierName,
            UUID currencyId,
            String currencyCode,
            String outstandingOriginal,
            String outstandingLocal,
            List<Item> items) {}
}
