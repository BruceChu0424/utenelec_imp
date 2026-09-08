package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * Frozen commercial consideration for procurement receipts. These amounts are
 * supplier charges only; they do not include company-owned subcontract inputs.
 * Inventory custody value must follow the physical source references separately.
 */
public interface ProcurementReceiptConsiderationPort {
    enum BillingMode {
        STANDARD, NO_CHARGE, CREDIT_REPURCHASE, LEGACY_UNCLASSIFIED
    }

    record Part(
            UUID id,
            String receiptType,
            UUID receiptId,
            UUID receiptItemId,
            BillingMode billingMode,
            UUID replacementAllocationId,
            UUID failureCaseId,
            UUID fundingSliceId,
            UUID rootFundingSliceId,
            UUID rootFailureCaseId,
            UUID creditSliceId,
            UUID sourceReceiptItemId,
            UUID rootReceiptItemId,
            UUID carriedFundingApId,
            UUID payableApId,
            BigDecimal baseQty,
            BigDecimal nominalOriginal,
            BigDecimal nominalLocal,
            BigDecimal payableOriginal,
            BigDecimal payableLocal) {
    }

    record QualityPart(
            UUID id,
            UUID considerationPartId,
            UUID inspectionItemId,
            UUID inspectionEventId,
            String action,
            BigDecimal baseQty) {
    }

    record StockPart(
            UUID id,
            UUID qualityPartId,
            UUID considerationPartId,
            UUID stockInItemId,
            BigDecimal baseQty) {
    }

    /** Includes every active part, including zero-charge physical replacements. */
    List<Part> receipt(String receiptType, UUID receiptId);

    /** Exact funding parts of one physical failure generation, never SKU matching. */
    List<Part> failure(UUID failureCaseId);

    Optional<QualityPart> failureQuality(UUID failureCaseId,UUID fundingSliceId);

    /** Exact commercial partition of one already recorded PASS or FAIL event. */
    List<QualityPart> quality(UUID inspectionEventId);

    /** Exact commercial partition of one actual warehouse stock-in item. */
    List<StockPart> stock(UUID stockInItemId);
}
