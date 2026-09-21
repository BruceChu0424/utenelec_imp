package com.uten.imp.application.concurrency;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialSource;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.core.Ordered;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.Collection;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;

/** Transaction ownership evidence; never a JVM-wide mutex. */
public final class FulfillmentLockState {
    private static final Object RESOURCE = new Object();
    private static final org.slf4j.Logger LOG = org.slf4j.LoggerFactory.getLogger(FulfillmentLockState.class);
    private FulfillmentLockState() { }

    static State current(boolean create) {
        if (!TransactionSynchronizationManager.isSynchronizationActive()) return null;
        State state = (State) TransactionSynchronizationManager.getResource(RESOURCE);
        if (state == null && create) {
            state = new State();
            TransactionSynchronizationManager.bindResource(RESOURCE, state);
            TransactionSynchronizationManager.registerSynchronization(state);
        }
        return state;
    }

    /** Called by the existing inventory mutex before issuing any advisory lock. */
    public static void beforeInventoryLocks(Collection<InventoryDimension> dimensions) {
        State state = current(true);
        if (state == null) return; // Direct non-Spring test construction has no transaction scope.
        if (state.closed) throw conflict("事务已完成，不能复用原库存锁");
        if (state.prepared && !state.inventory.containsAll(dimensions)) {
            throw retryableConflict("库存来源维度在预锁后变化，禁止持锁补拿新库存维度，请刷新后重试");
        }
        state.inventoryEntered = true;
    }

    /** 结构性违反(预锁顺序/归属错误): 重跑也不会变好。 */
    static ApiException conflict(String internalReason) {
        LOG.debug("Fulfillment mutation source conflict: {}", internalReason);
        return new FulfillmentSourceConflictException(internalReason, false);
    }

    /**
     * 瞬时冲突(等锁期间别的事务先提交, 预读集合过期): 本命令还没写任何东西, 事务整体回滚,
     * 最外层事务边界会用同一请求自动重跑(见 FulfillmentSourceConflictRetryInterceptor)。
     */
    static ApiException retryableConflict(String internalReason) {
        LOG.debug("Fulfillment mutation source conflict (retryable): {}", internalReason);
        return new FulfillmentSourceConflictException(internalReason, true);
    }

    static final class State implements TransactionSynchronization {
        final Set<CommercialSource> sources = new HashSet<>();
        final Set<InventoryDimension> inventory = new HashSet<>();
        final Set<UUID> warehouses = new HashSet<>();
        final Set<UUID> analyses = new HashSet<>();
        final Set<CommercialSource> expectedNewSources = new HashSet<>();
        final Set<UUID> expectedNewAnalyses = new HashSet<>();
        final com.uten.imp.common.concurrency.SavepointSnapshots<Snapshot> savepoints =
                new com.uten.imp.common.concurrency.SavepointSnapshots<>();
        boolean prepared;
        boolean inventoryEntered;
        boolean closed;
        private record Snapshot(Set<CommercialSource> sources, Set<InventoryDimension> inventory,
                Set<UUID> warehouses, Set<UUID> analyses, Set<CommercialSource> expectedNewSources,
                Set<UUID> expectedNewAnalyses, boolean prepared, boolean inventoryEntered) {}
        @Override public int getOrder() { return Ordered.HIGHEST_PRECEDENCE; }
        @Override public void savepoint(Object savepoint) {
            savepoints.record(savepoint, new Snapshot(Set.copyOf(sources), Set.copyOf(inventory),
                    Set.copyOf(warehouses), Set.copyOf(analyses), Set.copyOf(expectedNewSources),
                    Set.copyOf(expectedNewAnalyses), prepared, inventoryEntered));
        }
        @Override public void savepointRollback(Object savepoint) {
            Snapshot retained = savepoints.rollback(savepoint);
            sources.clear(); inventory.clear(); warehouses.clear(); analyses.clear();
            expectedNewSources.clear(); expectedNewAnalyses.clear();
            prepared = retained != null && retained.prepared();
            inventoryEntered = retained != null && retained.inventoryEntered();
            if (retained != null) {
                sources.addAll(retained.sources()); inventory.addAll(retained.inventory());
                warehouses.addAll(retained.warehouses()); analyses.addAll(retained.analyses());
                expectedNewSources.addAll(retained.expectedNewSources());
                expectedNewAnalyses.addAll(retained.expectedNewAnalyses());
            }
        }
        @Override public void suspend() {
            if (TransactionSynchronizationManager.getResource(RESOURCE) == this) {
                TransactionSynchronizationManager.unbindResource(RESOURCE);
            }
        }
        @Override public void resume() {
            if (!closed) TransactionSynchronizationManager.bindResource(RESOURCE, this);
        }
        @Override public void afterCommit() { clear(); }
        @Override public void afterCompletion(int status) {
            clear();
            if (TransactionSynchronizationManager.getResource(RESOURCE) == this) {
                TransactionSynchronizationManager.unbindResource(RESOURCE);
            }
        }
        private void clear() {
            closed = true;
            sources.clear(); inventory.clear(); warehouses.clear(); analyses.clear();
            expectedNewSources.clear(); expectedNewAnalyses.clear();
            savepoints.clear();
        }
    }
}
