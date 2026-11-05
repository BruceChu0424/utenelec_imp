package com.uten.imp.application.port;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import java.math.BigDecimal;
import java.util.Collection;
import java.util.List;
import java.util.UUID;

/** Exact order-path production entitlement handoff; no finished-product inventory is created. */
public interface SalesDeliveryFulfillmentPort {
    record Component(UUID componentId,UUID shipmentItemId,UUID orderItemId,List<UUID> path,
            UUID goodsId,UUID colorId,UUID unitId,BigDecimal quantity,UUID warehouseId,BigDecimal orderRowQty) {
        public Component { path=List.copyOf(path); }
    }
    /** Read-only prefix discovery, before any sales, inventory or analysis mutation row locks. */
    FulfillmentMutationLockPlan discover(Collection<UUID> orderItemIds,Collection<UUID> shipmentIds);
    /** Move only this order/path's qualified private stock to physical component custody. */
    void prepare(UUID shipmentId,List<Component> components);
    /** Called after all actual component movements succeed, in the same transaction. */
    void complete(UUID shipmentId);
    /** Called after actual movement reversal; restores source kits and their exact private lots. */
    void reverse(UUID shipmentId);
    /** Warehouse confirms an unprocessed issue returned; never release another path's private stock. */
    void cancelPreparedComponent(UUID componentId);
    void cancelPreparedShipment(UUID shipmentId);
}
