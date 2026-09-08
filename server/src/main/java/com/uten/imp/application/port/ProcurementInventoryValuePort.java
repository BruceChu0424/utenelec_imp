package com.uten.imp.application.port;

import java.util.UUID;

/** Same-transaction value hooks after the corresponding immutable commercial/quality facts exist. */
public interface ProcurementInventoryValuePort {
    void receiptApproved(String receiptType,UUID receiptId,UUID actorUserId);
    void qualityRecorded(UUID inspectionEventId,UUID actorUserId);
    void receiptReversed(String receiptType,UUID receiptId,UUID actorUserId);
    void qualityReversed(UUID inspectionEventId,UUID actorUserId);
    void creditConfirmed(UUID creditDocumentId,UUID actorUserId);
    void creditReversed(UUID originalCreditDocumentId,UUID actorUserId);
    void returnedToSupplier(UUID failureCaseId,UUID actorUserId);
    void returnReversed(UUID failureCaseId,UUID actorUserId);
}
