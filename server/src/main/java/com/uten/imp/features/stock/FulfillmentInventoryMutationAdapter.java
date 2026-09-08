package com.uten.imp.features.stock;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.application.port.InventoryMutationPort;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.Collection;

/** Keeps every lock on the same component used by reservations and inventory valuation. */
@Component
@RequiredArgsConstructor
public class FulfillmentInventoryMutationAdapter implements InventoryMutationPort {
    private final InventoryMutationLock inventory;
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void lockDimensions(Collection<InventoryDimension> dimensions) {
        inventory.lockAll(dimensions.stream().map(key -> new InventoryKey(key.goodsId(), key.colorId())).toList());
    }
}
