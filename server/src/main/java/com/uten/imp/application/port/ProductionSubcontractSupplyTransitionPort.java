package com.uten.imp.application.port;

import java.util.UUID;

/**
 * Transactional callbacks from subcontract documents into the production
 * fulfillment ledger. Implementations live in production; subcontract depends
 * only on this neutral contract.
 */
public interface ProductionSubcontractSupplyTransitionPort {

    void onSubcontractApplicationRemoved(UUID applicationId);

    void onSubcontractOrderApproved(UUID orderId);

    void onSubcontractOrderReversed(UUID orderId);

    void lockSubcontractReceiptMutationDimensions(UUID receiptId);

    void lockSubcontractReceiptProductionDemands(
            UUID receiptId, UUID warehouseId);

    void onSubcontractReceiptApproved(UUID receiptId);

    /**
     * Refreshes material-analysis availability after one IQC PASS movement.
     * Formal receipt fulfillment remains whole-receipt-only.
     */
    default void afterSubcontractInspectionPassed(
            UUID receiptId, UUID inspectionItemId, UUID dispositionEventId) {
        // Optional for test doubles and non-production adapters.
    }

    void beforeSubcontractReceiptReversed(UUID receiptId);

    /** Called after the receipt's qualified physical stock has been removed. */
    default void afterSubcontractReceiptReversed(UUID receiptId) {
        // Optional for test doubles and non-production adapters.
    }
}
