package com.uten.imp.application.port;

import java.util.UUID;

/** Business UUIDs only. A caller supplies neither a selling price nor a guessed value node. */
public sealed interface InventoryMovementCostReference permits
        InventoryMovementCostReference.ProcurementStockIn,
        InventoryMovementCostReference.ProductionMaterialEvent,
        InventoryMovementCostReference.FinishedProduction,
        InventoryMovementCostReference.SalesReturnQuality,
        InventoryMovementCostReference.OriginalIssueMovement {
    record ProcurementStockIn(UUID stockInItemId) implements InventoryMovementCostReference {}
    record ProductionMaterialEvent(UUID eventId) implements InventoryMovementCostReference {}
    record FinishedProduction(UUID executionSegmentId) implements InventoryMovementCostReference {}
    record SalesReturnQuality(UUID qualityItemId,UUID qualityEventId) implements InventoryMovementCostReference {}
    record OriginalIssueMovement(UUID originalMovementId) implements InventoryMovementCostReference {}
}
