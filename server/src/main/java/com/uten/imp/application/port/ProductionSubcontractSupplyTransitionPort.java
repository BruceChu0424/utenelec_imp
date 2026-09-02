package com.uten.imp.application.port;

import java.util.Collection;
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
     * Advances one warehouse-confirmed IQC stock-in batch (a single receipt's
     * confirmed slices, possibly many in one transaction) into material
     * analysis and formal production fulfillment. Implementations derive
     * cumulative warehouse-stocked quantity and subtract existing effective
     * allocations; must be invoked exactly once per confirmed batch, after all
     * of its slices have been recorded.
     */
    default void afterSubcontractInspectionStockInConfirmed(
            UUID receiptId, UUID warehouseStockInBatchId,
            Collection<UUID> inspectionItemIds) {
        // Optional for test doubles and non-production adapters.
    }

    void beforeSubcontractReceiptReversed(UUID receiptId);

    /** Called after the receipt's qualified physical stock has been removed. */
    default void afterSubcontractReceiptReversed(UUID receiptId) {
        // Optional for test doubles and non-production adapters.
    }
}
