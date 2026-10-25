package com.uten.imp.application.port;

import java.util.UUID;

/** Resolves the original warehouse and finance action cards after a procurement decision. */
public interface ProcurementClosureNoticePort {
    int resolveReviewNotices(String aggregateType, UUID aggregateId, String reason);
    void resolveArrivalExpectationNotices(String orderType, UUID orderId);
}
