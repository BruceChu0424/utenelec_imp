package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** Proven quantity revisions: pending reservations or approved sources, according to the locked lifecycle. */
public interface ProcurementOrderSourceRevisionPort {
    /** changeLogId is also the eventual procurement_order_qty_change_logs.id in this transaction. */
    record Line(UUID changeLogId, UUID orderItemId, BigDecimal oldQty,
                BigDecimal newQty, BigDecimal unitRate) {}

    /** Caller holds its order lock; no item quantity has changed. Pending orders retain unconfirmed reservations only. */
    void prepare(String orderType, UUID orderId, List<Line> changes);

    /** Call after item/header quantity and amount flush; case and matching change logs follow before commit. */
    void apply(String orderType, UUID orderId, List<UUID> changeLogIds);
}
