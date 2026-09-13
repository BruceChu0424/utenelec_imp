package com.uten.imp.features.production.analysis;

import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import jakarta.persistence.EntityTransaction;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.orm.jpa.EntityManagerHolder;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class MaterialAnalysisStructureScopeTest {
    private final EntityManager em = mock(EntityManager.class);
    private final EntityManagerFactory factory = mock(EntityManagerFactory.class);
    private final EntityTransaction transaction = mock(EntityTransaction.class);
    private final UUID analysisId = UUID.randomUUID();
    private EntityManagerHolder owner;

    @BeforeEach void bind() {
        when(em.getEntityManagerFactory()).thenReturn(factory);
        when(em.getTransaction()).thenReturn(transaction);
        owner = new EntityManagerHolder(em);
        TransactionSynchronizationManager.initSynchronization();
        TransactionSynchronizationManager.setActualTransactionActive(true);
        TransactionSynchronizationManager.bindResource(factory, owner);
    }
    @AfterEach void clear() {
        for (var synchronization : TransactionSynchronizationManager.getSynchronizations()) {
            synchronization.afterCompletion(TransactionSynchronization.STATUS_ROLLED_BACK);
        }
        TransactionSynchronizationManager.unbindResourceIfPossible(factory);
        TransactionSynchronizationManager.clear();
    }

    @Test void readsOnlyAtBoundariesAndNeverReusesAnotherAnalysisOrTransaction() {
        var snapshot = snapshot("before"); var reads = new AtomicInteger(); var coverage = new AtomicInteger();
        try (var scope = MaterialAnalysisStructureScope.open(em, analysisId,
                () -> { reads.incrementAndGet(); return snapshot; }, coverage::incrementAndGet)) {
            assertSame(snapshot, MaterialAnalysisStructureScope.current(em, List.of(analysisId)));
            assertNull(MaterialAnalysisStructureScope.current(em, List.of(UUID.randomUUID())));
            assertNull(MaterialAnalysisStructureScope.current(em, List.of(analysisId, UUID.randomUUID())));
            assertThrows(IllegalStateException.class,
                    () -> MaterialAnalysisStructureScope.open(em, analysisId, () -> snapshot, () -> {}));
            var synchronization = TransactionSynchronizationManager.getSynchronizations().getFirst();
            synchronization.suspend();
            TransactionSynchronizationManager.unbindResource(factory);
            TransactionSynchronizationManager.bindResource(factory, new EntityManagerHolder(mock(EntityManager.class)));
            assertNull(MaterialAnalysisStructureScope.current(em, List.of(analysisId)));
            TransactionSynchronizationManager.unbindResource(factory);
            TransactionSynchronizationManager.bindResource(factory, owner);
            synchronization.resume();
            assertSame(snapshot, MaterialAnalysisStructureScope.current(em, List.of(analysisId)));
        }
        assertEquals(2, reads.get()); assertEquals(1, coverage.get());
        assertNull(MaterialAnalysisStructureScope.current(em, List.of(analysisId)));
        verify(transaction, never()).setRollbackOnly();
    }

    @Test void changedMaterialOrRootsMarksRollbackAndClearsScope() {
        var current = new AtomicReference<>(snapshot("before"));
        var scope = MaterialAnalysisStructureScope.open(em, analysisId, current::get, () -> {});
        current.set(snapshot("after"));
        assertThrows(com.uten.imp.common.web.ApiException.class, scope::close);
        assertNull(MaterialAnalysisStructureScope.current(em, List.of(analysisId)));
        verify(transaction).setRollbackOnly();
    }

    @Test void cleanupPreservesOriginalFailureAndLeakedScopeCannotCommit() {
        var original = new IllegalStateException("original coverage failure");
        doThrow(new IllegalStateException("rollback cleanup failure")).when(transaction).setRollbackOnly();
        var actual = assertThrows(IllegalStateException.class, () -> MaterialAnalysisStructureScope.open(
                em, analysisId, () -> snapshot("before"), () -> { throw original; }));
        assertSame(original, actual); assertEquals(1, original.getSuppressed().length);
        assertNull(MaterialAnalysisStructureScope.current(em, List.of(analysisId)));
        reset(transaction);
        MaterialAnalysisStructureScope.open(em, analysisId, () -> snapshot("before"), () -> {});
        assertThrows(IllegalStateException.class, () -> TransactionSynchronizationManager.getSynchronizations()
                .getLast().beforeCommit(false));
        verify(transaction).setRollbackOnly();
    }

    private MaterialAnalysisStructureScope.Snapshot snapshot(String hash) {
        return new MaterialAnalysisStructureScope.Snapshot(List.of(analysisId),
                List.of(new MaterialAnalysisStructureScope.Row(analysisId, analysisId, null, hash)), List.of());
    }
}
