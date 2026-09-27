package com.uten.imp.features.production.mrp;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class AnalysisExecutionSnapshotScopeTest {
    private final UUID plan = UUID.randomUUID(), warehouse = UUID.randomUUID(), goods = UUID.randomUUID();

    @BeforeEach void transaction() {
        TransactionSynchronizationManager.initSynchronization();
        TransactionSynchronizationManager.setActualTransactionActive(true);
    }

    @AfterEach void clear() {
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.getSynchronizations().forEach(s -> s.afterCompletion(TransactionSynchronization.STATUS_ROLLED_BACK));
            TransactionSynchronizationManager.clearSynchronization();
        }
        TransactionSynchronizationManager.clear();
    }

    private ProductionExecutionPlanningService.Snapshot snapshot(UUID id) {
        var usage = new CompleteKitAllocator.MaterialUsage(goods, null, UUID.randomUUID(), BigDecimal.ONE, "BUY");
        var line = new CompleteKitAllocator.ProductLine(UUID.randomUUID(), 1, UUID.randomUUID(), null,
                UUID.randomUUID(), BigDecimal.ONE, BigDecimal.TEN, null, null, null, null, null,
                "P", "Product", null, List.of(usage), "b".repeat(64));
        return new ProductionExecutionPlanningService.Snapshot(id, warehouse, "a".repeat(64),
                List.of(line), Map.of(usage.materialKey(), BigDecimal.ONE), List.of());
    }

    @Test void reusesOnlyTheSameLockedPlanWarehouseAndEquivalentRoutes() {
        var snapshot = snapshot(plan);
        try (var ignored = AnalysisExecutionSnapshotScope.openLocked(snapshot)) {
            assertThat(AnalysisExecutionSnapshotScope.reusable(plan, warehouse, Map.of())).isSameAs(snapshot);
            assertThat(AnalysisExecutionSnapshotScope.reusable(plan, warehouse,
                    Map.of(new CompleteKitAllocator.MaterialKey(goods, null), "BUY"))).isSameAs(snapshot);
            assertThat(AnalysisExecutionSnapshotScope.reusable(UUID.randomUUID(), warehouse, Map.of())).isNull();
            assertThat(AnalysisExecutionSnapshotScope.reusable(plan, UUID.randomUUID(), Map.of())).isNull();
            assertThat(AnalysisExecutionSnapshotScope.reusable(plan, warehouse,
                    Map.of(new CompleteKitAllocator.MaterialKey(goods, null), "SUBCONTRACT"))).isNull();
        }
        assertThat(AnalysisExecutionSnapshotScope.reusable(plan, warehouse, Map.of())).isNull();
    }

    @Test void aSuspendedTransactionCannotReadItsParentsSnapshot() {
        try (var ignored = AnalysisExecutionSnapshotScope.openLocked(snapshot(plan))) {
            var original = TransactionSynchronizationManager.getSynchronizations();
            TransactionSynchronizationManager.clearSynchronization();
            TransactionSynchronizationManager.initSynchronization();
            assertThat(AnalysisExecutionSnapshotScope.reusable(plan, warehouse, Map.of())).isNull();
            TransactionSynchronizationManager.clearSynchronization();
            TransactionSynchronizationManager.initSynchronization();
            original.forEach(TransactionSynchronizationManager::registerSynchronization);
            assertThat(AnalysisExecutionSnapshotScope.reusable(plan, warehouse, Map.of())).isNotNull();
        }
    }

    @Test void nestedFormalWritesInvalidateBothPlansSharedInventoryBudgets() {
        try (var outer = AnalysisExecutionSnapshotScope.openLocked(snapshot(plan))) {
            UUID other = UUID.randomUUID();
            try (var inner = AnalysisExecutionSnapshotScope.openLocked(snapshot(other))) {
                AnalysisExecutionSnapshotScope.beforeFormalMutation();
                assertThat(AnalysisExecutionSnapshotScope.reusable(other, warehouse, Map.of())).isNull();
            }
            assertThat(AnalysisExecutionSnapshotScope.reusable(plan, warehouse, Map.of())).isNull();
        }
    }

    @Test void cannotOpenForReadOnlyOrWithoutAnExistingTransaction() {
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
        assertThatThrownBy(() -> AnalysisExecutionSnapshotScope.openLocked(snapshot(plan)))
                .isInstanceOf(IllegalStateException.class);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(false);
        TransactionSynchronizationManager.setActualTransactionActive(false);
        assertThatThrownBy(() -> AnalysisExecutionSnapshotScope.openLocked(snapshot(plan)))
                .isInstanceOf(IllegalStateException.class);
    }

    @Test void transactionCompletionDisposesAForgottenScopeWithoutLeakingToNextRequest() {
        var scope = AnalysisExecutionSnapshotScope.openLocked(snapshot(plan));
        TransactionSynchronizationManager.getSynchronizations().forEach(s -> s.afterCompletion(TransactionSynchronization.STATUS_COMMITTED));
        assertThat(AnalysisExecutionSnapshotScope.reusable(plan, warehouse, Map.of())).isNull();
        scope.close();
    }
}
