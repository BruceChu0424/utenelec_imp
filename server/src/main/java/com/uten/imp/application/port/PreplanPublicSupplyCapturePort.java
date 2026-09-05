package com.uten.imp.application.port;

import java.util.UUID;

/**
 * Same-transaction bridge from finance-effective procurement order state to
 * the append-only runtime public-supply ledger introduced by V474.
 */
public interface PreplanPublicSupplyCapturePort {

    PreplanPublicSupplyCapturePort NOOP = new PreplanPublicSupplyCapturePort() {
        @Override
        public void afterOrderApproved(String orderType, UUID orderId) {
        }

        @Override
        public void afterOrderReversed(String orderType, UUID orderId) {
        }
    };

    String PURCHASE = "PURCHASE";
    String SUBCONTRACT = "SUBCONTRACT";

    /** Reconcile direct-overorder public capacity after the order becomes approved. */
    void afterOrderApproved(String orderType, UUID orderId);

    /** Reconcile the same capacity after an unreceived order becomes reversed. */
    void afterOrderReversed(String orderType, UUID orderId);
}
