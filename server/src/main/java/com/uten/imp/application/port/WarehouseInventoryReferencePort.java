package com.uten.imp.application.port;

import java.util.List;
import java.util.Set;
import java.util.UUID;

/** Static inventory locations and explicit current-actor keeper assignments; no stock or cost data. */
public interface WarehouseInventoryReferencePort {
    record WarehouseReference(UUID id, String code, String name, UUID parentId,
                              boolean accountable, boolean lineSide) {}

    List<WarehouseReference> warehouses();

    /** Explicit assignments only. Unassigned warehouses in the task inbox are not an AI read grant. */
    Set<UUID> assignedWarehouseRoots();
}
