package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.UUID;

/**
 * Exact stock entitlement for an orderless customer dispatch; quantities are base units.
 * V631: every line carries its own issuing warehouse, so one dispatch may draw from several leaf warehouses.
 */
public interface CustomerShipmentInventoryPort {
    record Line(UUID itemId,UUID goodsId,UUID colorId,BigDecimal baseQty,UUID warehouseId) {}
    void reservePicking(UUID shipmentId,long revision,Collection<Line> lines);
    void consumeShipment(UUID shipmentId,Collection<Line> lines);
    void releaseUnpicked(UUID shipmentId);
    void requireNoUnreleased(UUID shipmentId);
}
