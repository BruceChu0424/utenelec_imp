package com.uten.imp.application.port;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import java.util.Collection;

/** Uses the existing shared inventory mutex and its transaction ownership proof. */
public interface InventoryMutationPort {
    void lockDimensions(Collection<InventoryDimension> dimensions);
}
