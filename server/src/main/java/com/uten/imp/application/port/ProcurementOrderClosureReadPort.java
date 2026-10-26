package com.uten.imp.application.port;

import java.time.OffsetDateTime;
import java.util.UUID;
import java.util.List;
import java.util.Map;

/** Closure progress for an already authorized business-order read. */
public interface ProcurementOrderClosureReadPort {
    ClosureRequestView latest(String orderType, UUID orderId);

    record ClosureRequestView(UUID caseId, String status, String mode, String reason,
                              String rejectionReason, OffsetDateTime submittedAt,
                              UUID replacementOrderId, String replacementBillNo,
                              String executionMode, OffsetDateTime closedAt, String closedByName,
                              List<Map<String,Object>> items,boolean unverifiedQuantity) {
        public ClosureRequestView(UUID caseId,String status,String mode,String reason,String rejectionReason,
                OffsetDateTime submittedAt,UUID replacementOrderId,String replacementBillNo) {
            this(caseId,status,mode,reason,rejectionReason,submittedAt,replacementOrderId,replacementBillNo,
                    null,null,null,List.of(),false);
        }
    }
}
