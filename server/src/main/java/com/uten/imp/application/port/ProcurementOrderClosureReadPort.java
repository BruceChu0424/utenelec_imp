package com.uten.imp.application.port;

import java.time.OffsetDateTime;
import java.util.UUID;

/** Closure progress for an already authorized business-order read. */
public interface ProcurementOrderClosureReadPort {
    ClosureRequestView latest(String orderType, UUID orderId);

    record ClosureRequestView(UUID caseId, String status, String mode, String reason,
                              String rejectionReason, OffsetDateTime submittedAt,
                              UUID replacementOrderId, String replacementBillNo) { }
}
