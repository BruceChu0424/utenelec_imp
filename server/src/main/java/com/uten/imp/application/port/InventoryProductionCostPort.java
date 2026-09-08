package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import com.uten.imp.application.port.InventoryValuationPort.*;

/**
 * Internal, approved production-cost allocation. Approval, actual-consumption
 * classification and effective execution target are caller-owned authorities;
 * this is not a public form accepting a freely chosen cost amount. All monetary
 * values are read from the exact registered value nodes.
 */
public interface InventoryProductionCostPort {
    enum ScopeKind { PRODUCTION_EXECUTION, SUBCONTRACT_RECEIPT_ITEM, SUBCONTRACT_ORDER_NORMAL_LOSS }
    /** The source UUID is a real business identity, never a synthetic execution segment. */
    record Scope(UUID sourceId, ScopeKind kind, PoolKey productPool) {}
    enum InputKind { CONSUMED, NORMAL_LOSS, CONFIRMED_PROCESSING_FEE }
    enum CostState { APPLYING, PROVISIONAL, FINAL, PENDING_BASIS, PENDING_CLASSIFICATION }
    record Input(UUID consumedPositionRootId, UUID approvedPostingId, InputKind kind) {}
    record Output(UUID finishedSourceNodeId, UUID movementId) {}

    /** inputs/outputs register new exact facts; previously registered facts remain in the same segment. */
    record Revision(EventContext context, UUID executionSegmentId, PoolKey productPool,
                    long expectedVersion, BigDecimal approvedTargetQtyBase,
                    boolean scopeComplete, UUID approvalEvidenceId, String approvalEvidenceHash,
                    List<Input> inputs, List<Output> outputs) {}
    record Revised(UUID revisionId, UUID executionSegmentId, long version,
                   long pendingTasks, CostState state, boolean replayed) {}
    record Work(UUID taskId, UUID executionSegmentId, PoolKey inputPool, PoolKey outputPool) {}
    record Applied(boolean applied, boolean replayed, boolean revisionComplete) {}
    record Recalculation(UUID executionSegmentId, UUID sourceEventId, long currentVersion) {}
    record CostPosition(UUID executionSegmentId, long version, BigDecimal targetQtyBase,
                        BigDecimal actualKnownCostLocal, BigDecimal allocatedToOutputsLocal,
                        BigDecimal heldWipLocal, BigDecimal pendingReallocationLocal,
                        BigDecimal unclassifiedLocal, CostState state, boolean pending) {}

    /** Bind before the physical inbound transaction commits; later cost work cannot reassign its execution identity. */
    void registerOutput(UUID executionSegmentId, PoolKey productPool, Output output);
    void registerScope(Scope scope);
    Scope scope(UUID sourceId);
    Revised revise(Revision command);
    /** Reuses the current approved plan, only refreshing its actual-cost sources. */
    Revised recalculate(EventContext context, UUID executionSegmentId, long expectedVersion);
    List<Work> pendingWork(int limit);
    List<Recalculation> pendingRecalculations(int limit);
    Applied apply(UUID taskId);
    CostPosition position(UUID executionSegmentId);
}
