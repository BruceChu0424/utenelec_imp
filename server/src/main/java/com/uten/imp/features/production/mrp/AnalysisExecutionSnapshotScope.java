package com.uten.imp.features.production.mrp;

import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.ArrayDeque;
import java.util.Deque;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * A locked snapshot for one analysis-derived plan's preview/save/approve window.
 * It never survives an inventory mutation, another plan, a suspended transaction
 * or the caller's try-with-resources block. Request/assignment validation remains live.
 */
public final class AnalysisExecutionSnapshotScope implements AutoCloseable {
    private static final ThreadLocal<Deque<AnalysisExecutionSnapshotScope>> ACTIVE = new ThreadLocal<>();
    private final ProductionExecutionPlanningService.Snapshot snapshot;
    private final Marker transaction;
    private boolean reusable = true;
    private boolean closed;

    private AnalysisExecutionSnapshotScope(ProductionExecutionPlanningService.Snapshot snapshot) {
        if (!TransactionSynchronizationManager.isActualTransactionActive()
                || !TransactionSynchronizationManager.isSynchronizationActive()
                || TransactionSynchronizationManager.isCurrentTransactionReadOnly()) {
            throw new IllegalStateException("An analysis planning snapshot requires its existing write transaction");
        }
        this.snapshot = Objects.requireNonNull(snapshot);
        this.transaction = new Marker();
        TransactionSynchronizationManager.registerSynchronization(transaction);
        Deque<AnalysisExecutionSnapshotScope> stack = ACTIVE.get();
        if (stack == null) {
            stack = new ArrayDeque<>();
            ACTIVE.set(stack);
        }
        stack.push(this);
    }

    static AnalysisExecutionSnapshotScope openLocked(ProductionExecutionPlanningService.Snapshot snapshot) {
        return new AnalysisExecutionSnapshotScope(snapshot);
    }

    static ProductionExecutionPlanningService.Snapshot reusable(
            UUID planId, UUID warehouseId, Map<CompleteKitAllocator.MaterialKey, String> overrides) {
        Deque<AnalysisExecutionSnapshotScope> stack = ACTIVE.get();
        if (stack == null || stack.isEmpty()
                || !TransactionSynchronizationManager.isActualTransactionActive()
                || !TransactionSynchronizationManager.isSynchronizationActive()) return null;
        AnalysisExecutionSnapshotScope scope = stack.peek();
        if (scope.closed || !scope.reusable || !scope.transaction.active
                || !TransactionSynchronizationManager.getSynchronizations().contains(scope.transaction)
                || !Objects.equals(planId, scope.snapshot.planId())
                || !Objects.equals(warehouseId, scope.snapshot.warehouseId())) return null;
        if (overrides != null) {
            for (var entry : overrides.entrySet()) {
                var matches = scope.snapshot.productLines().stream().flatMap(line -> line.materials().stream())
                        .filter(material -> material.materialKey().equals(entry.getKey())).toList();
                if (matches.isEmpty() || matches.stream().anyMatch(material ->
                        !Objects.equals(material.supplyRoute(), entry.getValue()))) return null;
            }
        }
        return scope.snapshot;
    }

    /** Invalidate enclosing scopes too: a nested plan may consume their shared stock. */
    static void beforeFormalMutation() {
        Deque<AnalysisExecutionSnapshotScope> stack = ACTIVE.get();
        if (stack != null) stack.forEach(scope -> scope.reusable = false);
    }

    @Override public void close() {
        if (closed) return;
        if (!transaction.active) { closed = true; reusable = false; return; }
        Deque<AnalysisExecutionSnapshotScope> stack = ACTIVE.get();
        if (stack == null || stack.peek() != this) {
            throw new IllegalStateException("Analysis planning scopes must close in nesting order");
        }
        closed = true;
        reusable = false;
        stack.pop();
        if (stack.isEmpty()) ACTIVE.remove();
    }

    private static final class Marker implements TransactionSynchronization {
        private boolean active = true;
        @Override public void afterCompletion(int status) {
            active = false;
            Deque<AnalysisExecutionSnapshotScope> stack = ACTIVE.get();
            if (stack != null) {
                stack.removeIf(scope -> scope.transaction == this);
                if (stack.isEmpty()) ACTIVE.remove();
            }
        }
    }
}
