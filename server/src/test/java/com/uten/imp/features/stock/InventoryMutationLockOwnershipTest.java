package com.uten.imp.features.stock;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Ownership bookkeeping only; real advisory locking is exercised by PostgreSQL suites. */
class InventoryMutationLockOwnershipTest {
    private InventoryMutationLock locks;
    private Query query;
    private final InventoryKey key = new InventoryKey(UUID.randomUUID(), null);

    @BeforeEach void begin() {
        EntityManager em = mock(EntityManager.class);
        query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        locks = new InventoryMutationLock(em);
        TransactionSynchronizationManager.setActualTransactionActive(true);
        TransactionSynchronizationManager.initSynchronization();
    }

    @AfterEach void end() {
        for (var synchronization : TransactionSynchronizationManager.getSynchronizations()) {
            synchronization.afterCompletion(TransactionSynchronization.STATUS_ROLLED_BACK);
        }
        TransactionSynchronizationManager.clearSynchronization();
        TransactionSynchronizationManager.setActualTransactionActive(false);
    }

    @Test void onlySuccessfullyAcquiredExactKeysAreOwned() {
        assertThatThrownBy(() -> locks.requireHeld(key)).isInstanceOf(IllegalStateException.class);
        locks.lock(key);
        assertThatCode(() -> locks.requireHeld(key)).doesNotThrowAnyException();
        assertThatThrownBy(() -> locks.requireHeld(new InventoryKey(key.goodsId(), UUID.randomUUID())))
                .isInstanceOf(IllegalStateException.class);
    }

    @Test void aSuspendedTransactionDoesNotAuthorizeTheInnerTransaction() {
        locks.lock(key);
        var outer = TransactionSynchronizationManager.getSynchronizations();
        outer.forEach(TransactionSynchronization::suspend);
        assertThatThrownBy(() -> locks.requireHeld(key)).isInstanceOf(IllegalStateException.class);
        outer.forEach(TransactionSynchronization::resume);
        assertThatCode(() -> locks.requireHeld(key)).doesNotThrowAnyException();
    }

    @Test void afterCommitCallbacksCannotReuseAnAlreadyReleasedMutex() {
        locks.lock(key);
        TransactionSynchronizationManager.getSynchronizations()
                .forEach(TransactionSynchronization::afterCommit);
        assertThatThrownBy(() -> locks.requireHeld(key)).isInstanceOf(IllegalStateException.class);
    }

    @Test void failedDatabaseLockAcquisitionNeverRecordsOwnership() {
        when(query.getSingleResult()).thenThrow(new IllegalStateException("lock failed"));
        assertThatThrownBy(() -> locks.lock(key)).hasMessage("lock failed");
        assertThatThrownBy(() -> locks.requireHeld(key)).isInstanceOf(IllegalStateException.class);
    }
}
