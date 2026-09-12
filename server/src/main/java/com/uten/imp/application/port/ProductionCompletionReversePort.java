package com.uten.imp.application.port;

import java.util.UUID;
import java.util.Collection;

/**
 * Neutral application port for reversing a finished-product inbound document
 * that may have completed one or more exact production execution segments.
 *
 * <p>The stock module owns the inventory document and its reversal transaction.
 * Production owns execution-segment lifecycle. The implementation must run in
 * the caller's transaction so reopening segments, reversing sales allocations,
 * reversing inventory, and changing the stock-document status are all-or-none.
 */
public interface ProductionCompletionReversePort {

    /**
     * Acquires every inventory dimension that a linked parent segment may
     * need, before the stock module locks the current FINISHED_IN dimensions.
     * This keeps concurrent receipts on one segment in one global lock order.
     */
    void lockFinishedInboundProductionDimensions(
            UUID stockDocumentId, UUID warehouseId);

    /**
     * Converts an approved finished-in line for a generated child plan into
     * exact parent MAKE coverage and promotes only a fully available parent
     * segment. The stock approval and production promotion share one
     * transaction.
     */
    void afterFinishedInboundApproved(
            UUID stockDocumentId, UUID warehouseId);

    /** Complete exact MAKE/subcontract handoffs for this document before the next physical posting. */
    void afterFinishedInboundPosted(UUID stockDocumentId, UUID warehouseId);

    /** Refresh analyses once after every document and its exact handoffs have completed. */
    void afterFinishedInboundBatchApproved(Collection<UUID> stockDocumentIds);
    /**
     * Locks and reopens every completed exact segment referenced by the
     * approved finished-in document. Documents without exact segment rows are
     * a legacy/manual no-op.
     */
    void beforeFinishedInboundReversed(UUID stockDocumentId);

    /** Called after FINISHED_IN physical stock has been removed. */
    default void afterFinishedInboundReversed(
            UUID stockDocumentId, UUID warehouseId) {
        // Optional for test doubles and legacy adapters.
    }
}
