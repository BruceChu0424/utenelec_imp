package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.UUID;

/** Exact stock entitlement for an orderless customer dispatch; quantities are base units. */
public interface CustomerShipmentInventoryPort {
    record Line(UUID itemId,UUID goodsId,UUID colorId,BigDecimal baseQty) {}
    void reservePicking(UUID shipmentId,UUID warehouseId,long revision,Collection<Line> lines);
    void consumeShipment(UUID shipmentId,UUID warehouseId,Collection<Line> lines);
    void releaseUnpicked(UUID shipmentId);
    void requireNoUnreleased(UUID shipmentId);
}
