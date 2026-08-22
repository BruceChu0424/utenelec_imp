package com.uten.imp.features.finance.payables;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** API records for subcontract excess-loss responsibility and claim fulfillment. */
public final class SubcontractLossClaimContracts {
    private SubcontractLossClaimContracts() {}

    public record DecisionRequest(
            long expectedVersion,
            boolean disputed,
            String reason,
            List<ResolutionInput> resolutions) {}

    public record ResolutionInput(
            UUID caseLineId,
            String type,
            BigDecimal quantity,
            BigDecimal amountLocal,
            LocalDate dueDate,
            String note,
            List<OffsetTarget> offsetTargets) {}

    public record OffsetTarget(UUID payableId, BigDecimal amountOriginal) {}

    public record FulfillmentRequest(
            long expectedCaseVersion,
            BigDecimal fulfilledQuantity,
            BigDecimal fulfilledAmountLocal,
            String evidenceReference,
            String fulfillmentDocType,
            UUID fulfillmentDocId,
            UUID fulfillmentDocItemId,
            String fulfillmentDocNo,
            UUID accountId,
            LocalDate cashReceiptDate,
            String note) {}

    public record ReverseRequest(long expectedVersion, String reason) {}
    public record ReverseFulfillmentRequest(long expectedCaseVersion,String reason) {}

    public record CaseSummary(
            UUID id,
            UUID wasteId,
            String wasteBillNo,
            UUID supplierId,
            String supplierCode,
            String supplierName,
            String status,
            String actualLossQty,
            String allowedLossQty,
            String excessLossQty,
            String lossBookValueLocal,
            String claimAmountLocal,
            long version,
            String createdAt) {}

    public record CaseLine(
            UUID id,
            UUID wasteItemId,
            UUID materialIssueItemId,
            UUID orderItemId,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            UUID colorId,
            UUID unitId,
            String actualLossQty,
            String allowedLossQty,
            String excessLossQty,
            String unitBookValueLocal,
            String lossBookValueLocal,
            String valuationStatus) {}

    public record Resolution(
            UUID id,
            UUID caseLineId,
            String type,
            String quantity,
            String amountLocal,
            String dueDate,
            String status,
            String note,
            String evidenceReference,
            String fulfillmentDocType,
            UUID fulfillmentDocId,
            String fulfillmentDocNo,
            UUID offsetLedgerId,
            String fulfilledAt) {}

    public record Event(
            UUID id,
            String type,
            UUID actorUserId,
            String reason,
            String createdAt) {}

    public record CaseDetail(
            CaseSummary summary,
            List<CaseLine> lines,
            List<Resolution> resolutions,
            List<Event> events) {}

    public record CasePage(
            List<CaseSummary> items,
            int page,
            int size,
            long total,
            int totalPages) {}
}
