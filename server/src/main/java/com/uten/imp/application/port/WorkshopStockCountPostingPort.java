package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/** Posts approved workshop counts in the approval transaction; facts are reread from the approved request. */
public interface WorkshopStockCountPostingPort {
    record LinePosting(UUID lineId, UUID postingId, UUID movementId) {}
    record PostingResult(List<LinePosting> lines) {}
    boolean canAccessWarehouse(UUID warehouseId);
    /** The same current-actor scope as canAccessWarehouse, resolved in bulk for read lists. */
    default java.util.Set<UUID> accessibleWarehouses(List<UUID> warehouseIds) {
        return warehouseIds.stream().filter(this::canAccessWarehouse).collect(java.util.stream.Collectors.toSet());
    }
    boolean canAccessWarehouseForUser(UUID warehouseId, UUID userId);
    PostingResult postApproved(UUID requestId, UUID approvalEventId);
}
