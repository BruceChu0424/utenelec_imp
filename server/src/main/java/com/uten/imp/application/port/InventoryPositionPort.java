package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import com.uten.imp.application.port.InventoryValuationPort.*;

/**
 * Exact custody-value moves before/after warehouse stock. These methods do not
 * change physical quantity. store runs before the caller's one physical inbound
 * movement in the same transaction, like InventoryValuationPort.receive.
 * Every involved InventoryMutationLock must already be held by the caller.
 */
public interface InventoryPositionPort {
    enum Owner { QUALITY_PENDING, QUALITY_PASSED, REJECTED_HOLD, SUPPLIER_CUSTODY,
        RETURN_INSPECTION, WIP, SUBCONTRACT_WIP, COST_WIP, LOSS, IN_TRANSIT, EXTERNAL, COGS }

    /** sourceSliceId identifies the actual quality/posting/allocation fact, not a SKU. */
    record Slice(UUID positionRootId, BigDecimal qtyBase, UUID sourceSliceId) {}
    record Acquire(EventContext context, PoolKey pool, UUID approvedEvidenceId,
                   long approvedEvidenceVersion, Owner owner, UUID ownerId,
                   List<Slice> carried) {}
    record Move(EventContext context, PoolKey pool, Owner owner, UUID ownerId,
                List<Slice> sources) {}
    /** Full reversal before any production input registration; never reverses an allocated input. */
    record RestoreConsumed(EventContext context,PoolKey pool,UUID originalPositionRootId,
                           UUID originalIssuePostingId,UUID reversalPostingId) {}
    /** Explicit consumption correction, including a partial correction after output allocation. */
    record ReturnConsumed(EventContext context,PoolKey pool,UUID originalPositionRootId,
                          BigDecimal qtyBase,Owner materialOwner,UUID materialOwnerId) {}
    record Store(EventContext context, UUID movementId, PoolKey pool,
                 BigDecimal expectedQtyBefore, List<Slice> sources, boolean pendingOwnMaterialCost) {
        public Store(EventContext context,UUID movementId,PoolKey pool,BigDecimal expectedQtyBefore,List<Slice> sources){
            this(context,movementId,pool,expectedQtyBefore,sources,false);
        }
    }
    /** Exact withdrawal of an unused, most-recent qualified inbound and its original custody slices. */
    record ReverseStore(EventContext context,UUID movementId,PoolKey pool,BigDecimal expectedQtyBefore,
                        UUID originalMovementId) {}
    record PositionValue(UUID eventId, UUID positionRootId, UUID fundingSourceNodeId,
                         BigDecimal qtyBase, BigDecimal knownValueLocal,
                         State state, boolean replayed) {}
    /** COST_WIP has no remaining physical quantity (null); its original basis is only allocation evidence. */
    record PositionView(UUID rootId, UUID remainingNodeId, PoolKey pool, Owner owner,
                        UUID ownerId, BigDecimal remainingQtyBase,
                        BigDecimal knownValueLocal, BigDecimal pendingReallocationLocal, State state) {}

    PositionValue acquire(Acquire command);
    PositionValue move(Move command);
    PositionValue restoreUnallocatedConsumed(RestoreConsumed command);
    PositionValue returnConsumed(ReturnConsumed command);
    MovementValue store(Store command);
    MovementValue reverseStore(ReverseStore command);
    PositionView position(UUID rootId);
}
