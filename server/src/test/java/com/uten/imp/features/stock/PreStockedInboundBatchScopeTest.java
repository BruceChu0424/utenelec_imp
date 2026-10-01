package com.uten.imp.features.stock;

import com.uten.imp.application.port.ProductionPreStockedInboundPort;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.atomic.AtomicBoolean;

import static org.junit.jupiter.api.Assertions.*;

class PreStockedInboundBatchScopeTest {
    private final List<UUID> posted = new ArrayList<>();
    private final HashSet<UUID> validated = new HashSet<>();
    private final List<List<UUID>> finishes = new ArrayList<>();
    private final AtomicBoolean rollbackOnly = new AtomicBoolean();

    @BeforeEach void start() {
        TransactionSynchronizationManager.initSynchronization();
        TransactionSynchronizationManager.setActualTransactionActive(true);
    }

    @AfterEach void end() {
        TransactionSynchronizationManager.getSynchronizations().forEach(sync -> sync.afterCompletion(0));
        TransactionSynchronizationManager.clearSynchronization();
        TransactionSynchronizationManager.setActualTransactionActive(false);
    }

    @Test void eachPostingIsImmediateAndTheSuccessfulCallbackFinishesOnce() {
        UUID first = UUID.randomUUID(), second = UUID.randomUUID();
        run(batch -> {
            batch.confirm(first, "first");
            assertEquals(List.of(first), posted);
            assertTrue(finishes.isEmpty());
            batch.confirm(second, "second");
            assertEquals(List.of(first, second), posted);
        });
        assertEquals(List.of(List.of(first, second)), finishes);
    }

    @Test void aFailedCallbackDoesNotFinishAndItsHandleCannotEscape() {
        var escaped = new AtomicReference<ProductionPreStockedInboundPort.Batch>();
        assertThrows(IllegalArgumentException.class, () -> run(batch -> {
            escaped.set(batch);
            batch.confirm(UUID.randomUUID(), "first");
            throw new IllegalArgumentException("second item rejected");
        }));
        assertTrue(finishes.isEmpty());
        assertTrue(rollbackOnly.get());
        assertThrows(IllegalStateException.class, () -> escaped.get().confirm(UUID.randomUUID(), "escaped"));
    }

    @Test void aSuccessfulHandleCannotBeUsedAgainInTheSameTransaction() {
        var escaped = new AtomicReference<ProductionPreStockedInboundPort.Batch>();
        run(escaped::set);
        assertThrows(IllegalStateException.class, () -> escaped.get().confirm(UUID.randomUUID(), "escaped"));
        assertTrue(finishes.isEmpty(), "普通先检后入批次没有实收入库, 不应触发分析刷新");
    }

    @Test void anotherThreadCannotUseTheBatchHandle() {
        try (var worker = Executors.newSingleThreadExecutor()) {
            assertThrows(IllegalStateException.class, () -> run(batch -> {
                var result = worker.submit(() -> assertThrows(IllegalStateException.class,
                        () -> batch.confirm(UUID.randomUUID(), "wrong-thread")));
                try { result.get(5, TimeUnit.SECONDS); }
                catch (Exception failure) { throw new AssertionError(failure); }
            }));
        }
        assertTrue(posted.isEmpty());
        assertTrue(rollbackOnly.get());
    }

    @Test void suspendedOuterBatchCannotBeUsedInAnIndependentTransaction() {
        UUID permitted = UUID.randomUUID();
        assertThrows(IllegalStateException.class, () -> run(batch -> {
            var outer = TransactionSynchronizationManager.getSynchronizations();
            TransactionSynchronizationManager.clearSynchronization();
            TransactionSynchronizationManager.initSynchronization();
            try {
                assertThrows(IllegalStateException.class, () -> batch.confirm(UUID.randomUUID(), "requires-new"));
            } finally {
                TransactionSynchronizationManager.clearSynchronization();
                TransactionSynchronizationManager.initSynchronization();
                outer.forEach(TransactionSynchronizationManager::registerSynchronization);
            }
            assertThrows(IllegalStateException.class, () -> batch.confirm(permitted, "outer-resumed"));
        }));
        assertTrue(finishes.isEmpty());
        assertTrue(rollbackOnly.get());
    }

    @Test void savepointRollbackRestoresPostedDocumentsAndWarehouseValidation() {
        UUID first = UUID.randomUUID(), rolledBack = UUID.randomUUID(), last = UUID.randomUUID();
        Object point = new Object();
        run(batch -> {
            batch.confirm(first, "first");
            TransactionSynchronizationManager.getSynchronizations().forEach(sync -> sync.savepoint(point));
            batch.confirm(rolledBack, "rolled-back");
            TransactionSynchronizationManager.getSynchronizations().forEach(sync -> sync.savepointRollback(point));
            assertEquals(List.of(first), posted);
            assertFalse(validated.contains(rolledBack));
            batch.confirm(last, "last");
        });
        assertEquals(List.of(List.of(first, last)), finishes);
    }

    @Test void theCallbackCannotRunWithoutTheOwnersTransaction() {
        TransactionSynchronizationManager.setActualTransactionActive(false);
        assertThrows(IllegalStateException.class, () -> run(batch -> fail("must not invoke work")));
    }

    @Test void swallowedConfirmationFailureStillPoisonsTheEntireBatch() {
        UUID first = UUID.randomUUID(), rejected = UUID.randomUUID();
        assertThrows(IllegalStateException.class, () -> PreStockedInboundBatchScope.run(posted, validated,
                (id, key) -> {
                    posted.add(id);
                    if (id.equals(rejected)) throw new IllegalArgumentException("after partial write");
                }, finishes::add, () -> rollbackOnly.set(true), batch -> {
                    batch.confirm(first, "first");
                    assertThrows(IllegalArgumentException.class, () -> batch.confirm(rejected, "rejected"));
                    assertThrows(IllegalStateException.class, () -> batch.confirm(UUID.randomUUID(), "cannot-continue"));
                }));
        assertTrue(rollbackOnly.get());
        assertTrue(finishes.isEmpty());
    }

    @Test void savepointRollbackDoesNotClearAFailedConfirmation() {
        Object point = new Object();
        assertThrows(IllegalStateException.class, () -> PreStockedInboundBatchScope.run(posted, validated,
                (id, key) -> { throw new IllegalArgumentException("rejected"); }, finishes::add,
                () -> rollbackOnly.set(true), batch -> {
                    TransactionSynchronizationManager.getSynchronizations().forEach(sync -> sync.savepoint(point));
                    assertThrows(IllegalArgumentException.class, () -> batch.confirm(UUID.randomUUID(), "rejected"));
                    TransactionSynchronizationManager.getSynchronizations().forEach(sync -> sync.savepointRollback(point));
                }));
        assertTrue(rollbackOnly.get());
        assertTrue(finishes.isEmpty());
    }

    private void run(java.util.function.Consumer<ProductionPreStockedInboundPort.Batch> work) {
        PreStockedInboundBatchScope.run(posted, validated,
                (id, key) -> { posted.add(id); validated.add(id); }, finishes::add, () -> rollbackOnly.set(true), work);
    }
}
