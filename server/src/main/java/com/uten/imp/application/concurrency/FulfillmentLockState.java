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
            throw conflict("库存来源维度在预锁后变化，禁止持锁补拿新库存维度，请刷新后重试");
        }
        state.inventoryEntered = true;
    }

    static ApiException conflict(String internalReason) {
        LOG.debug("Fulfillment mutation source conflict: {}", internalReason);
        return new ApiException(ErrorCode.CONFLICT,
                "相关订单、库存或任务信息已变化，请刷新后重新提交；本次操作未生效");
    }

    static final class State implements TransactionSynchronization {
        final Set<CommercialSource> sources = new HashSet<>();
        final Set<InventoryDimension> inventory = new HashSet<>();
        final Set<UUID> warehouses = new HashSet<>();
        final Set<UUID> analyses = new HashSet<>();
        final Set<CommercialSource> expectedNewSources = new HashSet<>();
        final Set<UUID> expectedNewAnalyses = new HashSet<>();
        boolean prepared;
        boolean inventoryEntered;
        boolean closed;
        @Override public int getOrder() { return Ordered.HIGHEST_PRECEDENCE; }
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
        }
    }
}
