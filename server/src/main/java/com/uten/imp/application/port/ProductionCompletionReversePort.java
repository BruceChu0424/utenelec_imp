package com.uten.imp.application.port;

import java.util.UUID;

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
     * Locks and reopens every completed exact segment referenced by the
     * approved finished-in document. Documents without exact segment rows are
     * a legacy/manual no-op.
     */
    void beforeFinishedInboundReversed(UUID stockDocumentId);
}
