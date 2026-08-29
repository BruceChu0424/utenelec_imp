package com.uten.imp.application.port;

import java.util.UUID;

/**
 * Neutral application port used by purchase documents to notify the
 * production material-supply ledger.
 *
 * <p>The purchase module owns order and receipt state. Production owns the
 * demand/peg/readiness transitions. Keeping this contract outside both feature
 * packages prevents a purchase-to-production implementation dependency while
 * preserving the same local transaction.</p>
 */
public interface ProductionSupplyTransitionPort {

    void onPurchaseOrderApproved(UUID orderId);

    void onPurchaseOrderReversed(UUID orderId);

    void lockPurchaseReceiptMutationDimensions(UUID receiptId);

    void lockReceiptProductionDemands(UUID receiptId, UUID warehouseId);

    void onPurchaseReceiptApproved(UUID receiptId);

    /**
     * Advances one IQC PASS slice into material analysis and formal production
     * fulfillment. Implementations must derive the cumulative qualified
     * quantity from the inspection ledger and subtract existing effective
     * receipt allocations, so replay and later PASS decisions are exact.
     */
    default void afterPurchaseInspectionPassed(
            UUID receiptId, UUID inspectionItemId, UUID dispositionEventId) {
        // Optional for test doubles and non-production adapters.
    }

    void beforePurchaseReceiptReversed(UUID receiptId);

    /** Called after the receipt's qualified physical stock has been removed. */
    default void afterPurchaseReceiptReversed(UUID receiptId) {
        // Optional for test doubles and non-production adapters.
    }
}
