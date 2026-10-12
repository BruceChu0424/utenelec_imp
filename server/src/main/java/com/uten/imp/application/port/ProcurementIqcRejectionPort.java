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
    /** Pure predicates shared with beforeReceiptReverse; no case updates or outbox. */
    default void requireReceiptReversible(String type,UUID id){throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.CONFLICT,"当前无法核对IQC失败后续事实");}

}
