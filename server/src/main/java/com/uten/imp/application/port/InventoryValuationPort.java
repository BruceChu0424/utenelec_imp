package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * Actual moving-average value, separate from physical quantity ownership.
 *
 * <p>The caller owns an active transaction and has already acquired the existing
 * InventoryMutationLock for all involved goods/color keys. Call a quantity
 * method BEFORE inserting its reserved movement UUID or changing stock_balances
 * quantity. Persist the returned canonical movement and apply its known value
 * exactly once in that same transaction. A replay never repeats either write.
 * Deferred database guards validate the final movement and pool projection.
 *
 * <p>Money/source permissions and source approval are the application adapter's
 * responsibility. This internal port is not a user-facing arbitrary-value API.
 * It never accepts a selling price for an outbound valuation.
 */
public interface InventoryValuationPort {
    enum State { FINAL, PENDING, LEGACY_UNVERIFIED }
    enum Destination { COGS, WIP, SUBCONTRACT_WIP, LOSS, IN_TRANSIT, EXTERNAL, RETURN_INSPECTION }

    record PoolKey(UUID warehouseId, UUID goodsId, UUID colorId) {}

    /**
     * Stable source sub-event/item identity, unique per logical operation even
     * if a retry changes its transport key. Split assignments need distinct
     * sub-events. Source time and responsibility must be stable on retry.
     */
    record EventContext(UUID sourceEventId, String sourceDocType, UUID sourceDocId,
                        UUID sourceItemId, long sourceVersion, UUID actorUserId,
                        UUID actorEmployeeId, String idempotencyKey, OffsetDateTime occurredAt) {}

    /** null knownCostLocal is only allowed with costFinal=false (unpriced, not free). */
    record Receive(EventContext context, UUID movementId, PoolKey pool,
                   BigDecimal qtyBase, BigDecimal expectedQtyBefore,
                   BigDecimal knownCostLocal, boolean costFinal) {}

    record Issue(EventContext context, UUID movementId, PoolKey pool,
                 BigDecimal qtyBase, BigDecimal expectedQtyBefore,
                 Destination destinationKind, UUID destinationId) {}

    /** Original-cost return or same-goods/color transfer-in from an exact issue. */
    record ReturnIssue(EventContext context, UUID movementId, PoolKey pool,
                       BigDecimal qtyBase, BigDecimal expectedQtyBefore,
                       UUID originalIssueNodeId) {}

    record SourceAdjustment(EventContext context, UUID sourceCostNodeId,
                            BigDecimal deltaLocal, boolean markFinal) {}

    /** knownValueLocal is the known component, never proof of a complete cost when PENDING. */
    record MovementValue(UUID eventId, UUID movementId, UUID valueNodeId, UUID poolHeadId,
                         BigDecimal knownValueLocal, State state, boolean replayed) {}

    record AdjustmentValue(UUID eventId, UUID sourceCostNodeId, long pendingTasks,
                           boolean replayed) {}

    /** Fetch without locks; in a new transaction acquire InventoryMutationLock(lockKey), then apply. */
    record PropagationWork(UUID taskId, UUID rootEventId, PoolKey lockKey) {}

    record PropagationResult(boolean applied, boolean replayed,
                             boolean waitingForPriorRevision, boolean jobComplete) {}

    /** Legacy knownValueLocal is null: its old recorded balance is not an approved opening cost. */
    record PoolValue(UUID poolId, UUID headNodeId, BigDecimal qtyBase,
                     BigDecimal knownValueLocal, State state, boolean propagationPending) {}

    MovementValue receive(Receive command);
    MovementValue issue(Issue command);
    MovementValue returnIssue(ReturnIssue command);
    AdjustmentValue adjustSource(SourceAdjustment command);
    /** Exact full LIFO reversal; the original propagation must have completed. */
    AdjustmentValue reverseAdjustment(EventContext context, UUID originalAdjustmentEventId);
    List<PropagationWork> pendingWork(int limit);
    PropagationResult propagate(UUID taskId);
    PoolValue pool(PoolKey key);
}
