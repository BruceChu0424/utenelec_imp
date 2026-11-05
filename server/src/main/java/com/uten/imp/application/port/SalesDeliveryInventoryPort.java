package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;
import java.util.Map;
import java.util.Collection;

/** Physical component quantities only; commercial parent quantities never enter this boundary. */
public interface SalesDeliveryInventoryPort {
    record Component(UUID id, UUID goodsId, UUID colorId, UUID unitId, BigDecimal quantity, UUID warehouseId) {}
    /** Public availability is a preview; original-order/private rights are validated on the real command. */
    record Choice(UUID warehouseId, String warehouseName, BigDecimal availableQty) {
        public boolean getRequiresSourceCheck(){return true;}
        public String getAvailableQtyExact(){return availableQty.stripTrailingZeros().toPlainString();}
    }
    List<Choice> choices(UUID goodsId, UUID colorId);
    Map<UUID,BigDecimal> ownedQuantities(Collection<UUID> componentIds);
    void reserveForProcessing(UUID componentId, UUID warehouseId, UUID goodsId, UUID colorId,
            UUID unitId, BigDecimal quantity, UUID requestId);
    void releaseProcessing(UUID componentId);
    void requireProcessingReservation(UUID componentId, UUID warehouseId, UUID goodsId, UUID colorId, BigDecimal quantity);
    void post(UUID shipmentId, List<Component> components, OffsetDateTime at);
    void reverse(UUID shipmentId, OffsetDateTime at);
}
