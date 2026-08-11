package com.uten.imp.application.port;

import java.util.Collection;
import java.util.UUID;

/**
 * Neutral application boundary for financially approved procurement arrivals.
 *
 * <p>The validation call may persist an exact-finance-assignee exception and throw
 * {@link ProcurementArrivalBlockedException}. Receipt approval transactions
 * must explicitly commit that exception while leaving inventory and AP
 * untouched.
 */
public interface ProcurementArrivalControlPort {

    String PURCHASE = "PURCHASE";
    String SUBCONTRACT = "SUBCONTRACT";

    void validateBeforeApproval(String orderType, UUID receiptId);

    void recordApproval(String orderType, UUID receiptId);

    void recordReversal(String orderType, UUID receiptId);

    void cancelForOrderReversal(String orderType, UUID orderId);

    void refreshAfterReturn(String orderType, Collection<UUID> orderItemIds);
}
