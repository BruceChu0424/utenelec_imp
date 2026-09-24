package com.uten.imp.application.concurrency;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialSource;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.common.web.ApiException;
import org.springframework.core.Ordered;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.Collection;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;

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

    /**
     * Called by the existing inventory mutex before issuing any advisory lock. 维度来自调用方读库的结果,
     * 可能随别的事务变化, 超出预锁按可重跑冲突处理。
     */
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
     * 调用方<b>声明的已知 id</b>超出本事务已持有的预锁集合: 这是足迹声明漏了东西(编码缺陷),
     * 同一请求重跑多少遍结果都一样, 不重跑, 记 ERROR 让它暴露出来(ADR-107)。
     */
    static ApiException coverageGap(String internalReason) {
        LOG.error("Fulfillment prelock coverage gap (structural, not retried): {}", internalReason);
        return new FulfillmentSourceConflictException(internalReason, false);
    }

    /**
     * <b>重新发现</b>得到的足迹超出已持有集合: 可能是编码缺陷, 也可能是预读之后别的事务改了
     * 依赖图里不拿锁的部分(例如给产品加了一个硬门槛子件)。事务整体回滚后可重跑; 记 WARN 留下缺少的 id,
     * 同一请求反复重跑仍缺, 拦截器放弃时还会再记一次。
     */
    static ApiException discoveredCoverageGap(String internalReason) {
        LOG.warn("Fulfillment prelock coverage gap found by rediscovery (retryable): {}", internalReason);
        return new FulfillmentSourceConflictException(internalReason, true);
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
        /** 本事务唯一一次完整预读得到的计划; 锁后复核拿它比对。 */
        FulfillmentMutationLockPlan prefixPlan;
        Supplier<FulfillmentMutationLockPlan> prefixDiscovery;
        /** 锁后复核(逐行版本相等)已做过: 之后再调复核不读库(自己的写入会改变行版本)。 */
        boolean prefixVerified;
        /** 锁后复核或嵌套入口的锁后覆盖复核已做过其一。 */
        boolean prefixRechecked;
        private record Snapshot(Set<CommercialSource> sources, Set<InventoryDimension> inventory,
                Set<UUID> warehouses, Set<UUID> analyses, Set<CommercialSource> expectedNewSources,
                Set<UUID> expectedNewAnalyses, boolean prepared, boolean inventoryEntered,
                FulfillmentMutationLockPlan prefixPlan, Supplier<FulfillmentMutationLockPlan> prefixDiscovery,
                boolean prefixVerified, boolean prefixRechecked) {}
        @Override public int getOrder() { return Ordered.HIGHEST_PRECEDENCE; }
        @Override public void savepoint(Object savepoint) {
            savepoints.record(savepoint, new Snapshot(Set.copyOf(sources), Set.copyOf(inventory),
                    Set.copyOf(warehouses), Set.copyOf(analyses), Set.copyOf(expectedNewSources),
                    Set.copyOf(expectedNewAnalyses), prepared, inventoryEntered,
                    prefixPlan, prefixDiscovery, prefixVerified, prefixRechecked));
        }
        @Override public void savepointRollback(Object savepoint) {
            Snapshot retained = savepoints.rollback(savepoint);
            sources.clear(); inventory.clear(); warehouses.clear(); analyses.clear();
            expectedNewSources.clear(); expectedNewAnalyses.clear();
            prepared = retained != null && retained.prepared();
            inventoryEntered = retained != null && retained.inventoryEntered();
            prefixPlan = retained == null ? null : retained.prefixPlan();
            prefixDiscovery = retained == null ? null : retained.prefixDiscovery();
            prefixVerified = retained != null && retained.prefixVerified();
            prefixRechecked = retained != null && retained.prefixRechecked();
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
            prefixPlan = null; prefixDiscovery = null;
            savepoints.clear();
        }
    }
}
