package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/** Retire only the unfulfilled source commitment, preserving original commercial evidence. */
public interface ProcurementOrderTerminationSourcePort {
    void apply(String orderType, UUID orderId, UUID caseId,
               List<ProcurementOrderApprovalPort.RemainingLine> lines);

    void linkReplacement(String orderType, UUID orderId, UUID replacementOrderId, UUID caseId);
}
