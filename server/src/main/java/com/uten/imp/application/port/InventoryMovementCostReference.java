package com.uten.imp.application.port;

import java.util.UUID;

/** Business UUIDs only. A caller supplies neither a selling price nor a guessed value node. */
public sealed interface InventoryMovementCostReference permits
        InventoryMovementCostReference.ProcurementStockIn,
        InventoryMovementCostReference.ProductionMaterialEvent,
        InventoryMovementCostReference.FinishedProduction,
        InventoryMovementCostReference.SalesReturnQuality,
        InventoryMovementCostReference.WorkshopReturn,
        InventoryMovementCostReference.OriginalIssueMovement {
    record ProcurementStockIn(UUID stockInItemId) implements InventoryMovementCostReference {}
    record ProductionMaterialEvent(UUID eventId) implements InventoryMovementCostReference {}
    record FinishedProduction(UUID executionSegmentId) implements InventoryMovementCostReference {}
    record SalesReturnQuality(UUID qualityItemId,UUID qualityEventId) implements InventoryMovementCostReference {}
    record OriginalIssueMovement(UUID originalMovementId) implements InventoryMovementCostReference {}
    enum WorkshopReturnKind { RETURN_IN, DIRECT_OUT, DIRECT_IN, RETURN_REVERSE, DIRECT_IN_REVERSE, DIRECT_OUT_REVERSE }
    /** Exact request/physical counterpart identities; never a caller-supplied unit cost. */
    record WorkshopReturn(UUID requestItemId, WorkshopReturnKind kind, UUID linkedMovementId)
            implements InventoryMovementCostReference {}
}
