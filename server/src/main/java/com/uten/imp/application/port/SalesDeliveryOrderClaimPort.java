package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.Map;
import java.util.UUID;

/** Subclaims of the same sales order's original root stock; never transfers reservation ownership. */
public interface SalesDeliveryOrderClaimPort {
    void prepare(UUID componentId,UUID warehouseId,BigDecimal quantity,UUID requestId);
    Map<UUID,BigDecimal> heldQuantities(Collection<UUID> componentIds);
    void consume(UUID componentId);
    void reverse(UUID shipmentId);
    void cancel(UUID componentId);
}
