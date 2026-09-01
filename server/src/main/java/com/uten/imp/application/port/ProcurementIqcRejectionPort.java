package com.uten.imp.application.port;

import java.util.UUID;

/** Finance-side projection/closure for procurement IQC failures. */
public interface ProcurementIqcRejectionPort {
    /**
     * Called only by the asynchronous business-outbox worker.  The quality
     * transaction never calls this method and therefore never depends on AP.
     */
    void projectDetected(
            UUID outboxEventId,
            String receiptType,
            UUID receiptId,
            UUID inspectionItemId,
            UUID inspectionEventId,
            UUID actorUserId);

    void beforeReceiptReverse(String receiptType, UUID receiptId);
}
