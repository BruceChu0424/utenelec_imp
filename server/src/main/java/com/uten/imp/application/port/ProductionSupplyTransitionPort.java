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

    void beforePurchaseReceiptReversed(UUID receiptId);

    /** Called after the receipt's qualified physical stock has been removed. */
    default void afterPurchaseReceiptReversed(UUID receiptId) {
        // Optional for test doubles and non-production adapters.
    }
}
