package com.uten.imp.application.port;

import java.util.UUID;

/** Actual returned-goods custody, independent of customer selling price/credit amounts. */
public interface SalesReturnInventoryValuePort {
    void receivedForInspection(UUID returnId,UUID actorUserId);
    void untouchedReceiptReversed(UUID returnId,UUID actorUserId);
    /** Called after the actual quality event; GOOD's physical movement carries its explicit cost reference. */
    void qualityEventRecorded(UUID qualityEventId,UUID actorUserId);
}
