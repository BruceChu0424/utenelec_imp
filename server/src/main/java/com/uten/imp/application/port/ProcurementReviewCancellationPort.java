package com.uten.imp.application.port;

import java.util.UUID;

/** Called inside an owner-authorized order transaction; active review leases block cancel/reverse. */
public interface ProcurementReviewCancellationPort {
    void cancelUnclaimedPending(String orderType,UUID orderId,String sourceAction);
}
