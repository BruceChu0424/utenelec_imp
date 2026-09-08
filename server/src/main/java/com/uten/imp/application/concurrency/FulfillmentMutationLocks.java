package com.uten.imp.application.concurrency;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialSource;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialType;
import com.uten.imp.application.port.InventoryMutationPort;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.Collection;
import java.util.Comparator;
import java.util.List;
import java.util.Objects;
import java.util.UUID;
import java.util.function.Supplier;

/** Commercial heads/items -> complete inventory -> main warehouses -> analyses. */
@Component
@RequiredArgsConstructor
public class FulfillmentMutationLocks {
    private final EntityManager em;
    private final InventoryMutationPort inventory;

    /** Discovery is read-only. Caller keeps existing plan/package/segment/physical row locks after this prefix. */
    @Transactional(propagation = Propagation.MANDATORY)
    public Guard acquire(Supplier<FulfillmentMutationLockPlan> discovery) {
        Objects.requireNonNull(discovery);
        FulfillmentMutationLockPlan plan = Objects.requireNonNull(discovery.get());
        FulfillmentLockState.State state = state();
        if (state.prepared) {
            requireCovered(plan);
            return new Guard(plan, discovery, state);
        }
        if (state.inventoryEntered) {
            throw FulfillmentLockState.conflict("已进入库存锁阶段，不能再补商业来源前缀，请刷新后重试");
        }
        // Every source head precedes every source item, including shared request/application sources.
        for (CommercialType type : CommercialType.values()) {
            List<UUID> ids = sourceIds(plan, type);
            if (ids.isEmpty()) continue;
            List<?> rows = em.createNativeQuery("SELECT id FROM " + type.headerTable
                    + " WHERE id IN (:ids) ORDER BY id FOR UPDATE")
                    .setParameter("ids", ids).getResultList();
            if (rows.size() != ids.size()) throw FulfillmentLockState.conflict("商业来源已不存在，请刷新后重试");
        }
        for (CommercialType type : CommercialType.values()) {
            List<UUID> ids = sourceIds(plan, type);
            if (!ids.isEmpty()) em.createNativeQuery("SELECT id FROM " + type.itemTable
                    + " WHERE " + type.parentColumn + " IN (:ids) ORDER BY " + type.parentColumn + ",id FOR UPDATE")
                    .setParameter("ids", ids).getResultList();
        }
        state.sources.addAll(plan.commercialSources());
        state.inventory.addAll(plan.inventoryDimensions());
        state.prepared = true;
        // Freeze the declared inventory set even for a source-only command.
        inventory.lockDimensions(plan.inventoryDimensions().stream().sorted().toList());
        state.inventoryEntered = true;
        for (UUID warehouse : sorted(plan.mainWarehouseIds())) {
            em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                    .setParameter("key", "MATERIAL-ANALYSIS-WAREHOUSE:" + warehouse).getSingleResult();
        }
        state.warehouses.addAll(plan.mainWarehouseIds());
        if (!plan.analysisIds().isEmpty()) {
            List<?> rows = em.createNativeQuery("""
                    SELECT id FROM production_material_analyses
                    WHERE id IN (:ids) ORDER BY id FOR UPDATE
                    """).setParameter("ids", sorted(plan.analysisIds())).getResultList();
            if (rows.size() != plan.analysisIds().size()) {
                throw FulfillmentLockState.conflict("关联物料分析已不存在，请刷新后重试");
            }
        }
        state.analyses.addAll(plan.analysisIds());
        return new Guard(plan, discovery, state);
    }

    /** For callbacks after their own writes: only coverage, never the pre-write status fingerprint. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireCovered(FulfillmentMutationLockPlan needed) {
        FulfillmentLockState.State state = state();
        if (!state.prepared || !state.sources.containsAll(needed.commercialSources())
                || !state.inventory.containsAll(needed.inventoryDimensions())
                || !state.warehouses.containsAll(needed.mainWarehouseIds())
                || !state.analyses.containsAll(needed.analysisIds())) {
            throw FulfillmentLockState.conflict("回调来源超出本次完整预锁集合，禁止持锁补拿上游目标，请刷新后重试");
        }
    }

    /** Call immediately before a plain INSERT of a newly generated UUID, never an upsert. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void expectCreatedSource(CommercialSource source) {
        FulfillmentLockState.State state = state();
        if (!state.prepared || exists(source.type().headerTable, source.id())) {
            throw FulfillmentLockState.conflict("新来源 UUID 必须尚不存在，已有来源必须提前预锁");
        }
        state.expectedNewSources.add(source);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void expectCreatedAnalysis(UUID id) {
        FulfillmentLockState.State state = state();
        if (!state.prepared || exists("production_material_analyses", id)) {
            throw FulfillmentLockState.conflict("新分析 UUID 必须尚不存在，已有分析必须提前预锁");
        }
        state.expectedNewAnalyses.add(id);
    }

    /** Both the new row and its database INSERT audit evidence must belong to this transaction. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void registerCreatedSource(CommercialSource source) {
        FulfillmentLockState.State state = state();
        if (!state.prepared || !state.expectedNewSources.contains(source)
                || !createdHere(source.type().headerTable, source.id())) {
            throw FulfillmentLockState.conflict("只能登记本事务新建的商业来源，已有来源必须提前预锁");
        }
        state.sources.add(source);
        state.expectedNewSources.remove(source);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void registerCreatedAnalysis(UUID analysisId, UUID mainWarehouseId) {
        FulfillmentLockState.State state = state();
        if (!state.prepared || !state.expectedNewAnalyses.contains(analysisId)
                || !state.warehouses.contains(mainWarehouseId)
                || !createdHere("production_material_analyses", analysisId)) {
            throw FulfillmentLockState.conflict("只能在已锁主仓登记本事务新建分析，已有分析必须提前预锁");
        }
        state.analyses.add(analysisId);
        state.expectedNewAnalyses.remove(analysisId);
    }

    private boolean exists(String table, UUID id) {
        return Boolean.TRUE.equals(em.createNativeQuery("SELECT EXISTS (SELECT 1 FROM " + table + " WHERE id=:id)")
                .setParameter("id", id).getSingleResult());
    }

    private boolean createdHere(String table, UUID id) {
        return Boolean.TRUE.equals(em.createNativeQuery("SELECT EXISTS (SELECT 1 FROM " + table
                + " WHERE id=:id AND xmin::text::numeric = mod(pg_current_xact_id()::text::numeric,4294967296))"
                + " AND EXISTS (SELECT 1 FROM audit_log WHERE target_type=:table AND target_id=:recordId"
                + " AND action='insert' AND event_source='database' AND before IS NULL"
                + " AND xmin::text::numeric = mod(pg_current_xact_id()::text::numeric,4294967296))")
                .setParameter("id", id).setParameter("table", table).setParameter("recordId", id.toString())
                .getSingleResult());
    }

    private FulfillmentLockState.State state() {
        if (!TransactionSynchronizationManager.isActualTransactionActive()) {
            throw new IllegalStateException("Fulfillment prelocking requires the caller's transaction");
        }
        FulfillmentLockState.State state = FulfillmentLockState.current(true);
        if (state == null || state.closed) throw new IllegalStateException("Completed transaction cannot reuse mutation locks");
        return state;
    }

    private static List<UUID> sourceIds(FulfillmentMutationLockPlan plan, CommercialType type) {
        return plan.commercialSources().stream().filter(source -> source.type() == type)
                .map(CommercialSource::id).sorted(Comparator.comparing(UUID::toString)).toList();
    }
    private static List<UUID> sorted(Collection<UUID> ids) {
        return ids.stream().distinct().sorted(Comparator.comparing(UUID::toString)).toList();
    }

    public final class Guard {
        private final FulfillmentMutationLockPlan plan;
        private final Supplier<FulfillmentMutationLockPlan> discovery;
        private final FulfillmentLockState.State transaction;
        private Guard(FulfillmentMutationLockPlan plan, Supplier<FulfillmentMutationLockPlan> discovery,
                      FulfillmentLockState.State transaction) {
            this.plan = plan; this.discovery = discovery; this.transaction = transaction;
        }
        public FulfillmentMutationLockPlan plan() { return plan; }
        /** Invoke after locking the mutable execution/root rows, before this command's first write. */
        public void verifyUnchanged() {
            if (transaction != state() || !plan.equals(discovery.get())) {
                throw FulfillmentLockState.conflict("来源集合在预读后变化，请刷新并重新提交；本次未补拿新锁");
            }
            requireCovered(plan);
        }
    }
}
