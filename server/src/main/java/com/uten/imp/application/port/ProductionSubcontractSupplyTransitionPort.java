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
     * Advances one IQC PASS slice into material analysis and formal production
     * fulfillment. Implementations must derive the cumulative qualified
     * quantity from the inspection ledger and subtract existing effective
     * receipt allocations, so replay and later PASS decisions are exact.
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
