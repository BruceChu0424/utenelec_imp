package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/**
 * Static inventory locations; no stock or cost data. Who may read which warehouse is decided by
 * {@link WarehouseTaskScopePort#access()} (ADR-149), not here.
 */
public interface WarehouseInventoryReferencePort {
    /** defective = 不良品仓(ADR-146): 可以查现存, 但不计入任何可用量。 */
    record WarehouseReference(UUID id, String code, String name, UUID parentId,
                              boolean accountable, boolean lineSide, boolean defective) {}

    List<WarehouseReference> warehouses();
}
