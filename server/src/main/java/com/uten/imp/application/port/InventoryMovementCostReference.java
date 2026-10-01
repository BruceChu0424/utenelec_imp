package com.uten.imp.application.port;

import java.util.UUID;

/** Business UUIDs only. A caller supplies neither a selling price nor a guessed value node. */
public sealed interface InventoryMovementCostReference permits
        InventoryMovementCostReference.ProcurementStockIn,
        InventoryMovementCostReference.ProductionMaterialEvent,
        InventoryMovementCostReference.FinishedProduction,
        InventoryMovementCostReference.SalesReturnQuality,
        InventoryMovementCostReference.WorkshopReturn,
        InventoryMovementCostReference.OriginalIssueMovement,
        InventoryMovementCostReference.WorkshopMaterialBin {
    record ProcurementStockIn(UUID stockInItemId) implements InventoryMovementCostReference {}
    record ProductionMaterialEvent(UUID eventId) implements InventoryMovementCostReference {}
    record FinishedProduction(UUID executionSegmentId) implements InventoryMovementCostReference {}
    record SalesReturnQuality(UUID qualityItemId,UUID qualityEventId) implements InventoryMovementCostReference {}
    record OriginalIssueMovement(UUID originalMovementId) implements InventoryMovementCostReference {}
    enum WorkshopReturnKind { RETURN_IN, DIRECT_OUT, DIRECT_IN, RETURN_REVERSE, DIRECT_IN_REVERSE, DIRECT_OUT_REVERSE }
    /** Exact request/physical counterpart identities; never a caller-supplied unit cost. */
    record WorkshopReturn(UUID requestItemId, WorkshopReturnKind kind, UUID linkedMovementId)
            implements InventoryMovementCostReference {}
    /** ADR-131 车间内料仓: 发料/退回/其它耗用的调出一侧与盘点耗用/盘盈及其冲回。 */
    enum WorkshopMaterialBinKind { ISSUE_OUT, RETURN_OUT, OTHER_ISSUE_OUT, CONSUME, CONSUME_REVERSE, GAIN, GAIN_REVERSE,
        COUNT_OPENING, COUNT_ADJUSTMENT_IN, COUNT_ADJUSTMENT_OUT }
    /**
     * sourceId: 发料/退回/其它耗用为本事务登记过的库存单据 id; 盘点耗用/盘盈及其冲回为本事务的盘点过账行 id。
     * 库存侧逐笔核对登记后才记账, 调用方不带单价。
     */
    record WorkshopMaterialBin(UUID sourceId, WorkshopMaterialBinKind kind) implements InventoryMovementCostReference {}
}
