package com.uten.imp.features.stock;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.core.Ordered;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.Collection;
import java.util.List;
import java.util.HashSet;
import java.util.Set;

/**
 * Serializes inventory balances and global reservations on the same logical
 * goods/color dimension.
 *
 * <p>Document row locks cannot protect two different orders competing for the
 * same stock. PostgreSQL transaction advisory locks provide that missing
 * cross-document mutex and are released automatically on commit/rollback.
 */
@Component
@RequiredArgsConstructor
public class InventoryMutationLock {

    /** Fixed server-side namespace/seed; never derived from a JVM hash code. */
    static final long HASH_NAMESPACE = 0x5554454E494D504CL;
    private static final int KEYS_PER_STATEMENT = 500;

    private final EntityManager em;
    private final Object heldKeysResource = new Object();

    /**
     * Acquires every requested key once, in a deterministic order.
     *
     * <p>Stable ordering prevents the A-then-B/B-then-A deadlock pattern for
     * multi-line documents.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void lockAll(Collection<InventoryKey> requested) {
        if (requested == null || requested.isEmpty()) {
            return;
        }
        List<InventoryKey> keys = requested.stream().distinct().sorted().toList();
        com.uten.imp.application.concurrency.FulfillmentLockState.beforeInventoryLocks(keys.stream()
                .map(key -> new com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension(
                        key.goodsId(), key.colorId())).toList());
        for (int from = 0; from < keys.size(); from += KEYS_PER_STATEMENT) {
            List<InventoryKey> chunk = keys.subList(from, Math.min(from + KEYS_PER_STATEMENT, keys.size()));
            // Keep the existing key, namespace and Java order. The ordered
            // subquery feeds the volatile lock function in that exact order;
            // OFFSET 0 preserves the ordering boundary under generic plans.
            // Always reacquire in PostgreSQL: an earlier savepoint rollback may
            // have released a lock even while Java still remembers the key.
            List<?> acquired = em.createNativeQuery("""
                            SELECT pg_advisory_xact_lock(
                                hashtextextended(ordered.inventory_key, CAST(:namespace AS bigint)))
                            FROM (
                                SELECT inventory_key
                                FROM unnest(string_to_array(:inventoryKeys, ','))
                                     WITH ORDINALITY AS requested(inventory_key, position)
                                ORDER BY position OFFSET 0
                            ) ordered
                            """)
                    .setParameter("inventoryKeys", chunk.stream().map(InventoryKey::canonical)
                            .collect(java.util.stream.Collectors.joining(",")))
                    .setParameter("namespace", HASH_NAMESPACE)
                    .getResultList();
            if (acquired.size() != chunk.size()) {
                throw new IllegalStateException("Inventory lock batch did not acquire every requested key");
            }
            chunk.forEach(this::recordAcquired);
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void lock(InventoryKey key) {
        lockAll(List.of(key));
    }

    /**
     * Runtime precondition for value posting: the caller has already acquired
     * this exact mutex through the shared lock component in this transaction.
     * Does not acquire a late lock or query all server locks on every movement.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireHeld(InventoryKey key) {
        HeldKeys held = (HeldKeys) TransactionSynchronizationManager.getResource(heldKeysResource);
        if (!TransactionSynchronizationManager.isActualTransactionActive()
                || held == null || held.closed || !held.keys.contains(key.canonical())) {
            throw new IllegalStateException("Inventory value posting requires its goods/color mutex in the current transaction");
        }
    }

    private void recordAcquired(InventoryKey key) {
        // Normal Spring callers are guarded by MANDATORY. Standalone lock-query
        // tests do not create a fictitious ownership proof without a real scope.
        if (!TransactionSynchronizationManager.isActualTransactionActive()
                || !TransactionSynchronizationManager.isSynchronizationActive()) return;
        HeldKeys held = (HeldKeys) TransactionSynchronizationManager.getResource(heldKeysResource);
        if (held == null) {
            held = new HeldKeys();
            TransactionSynchronizationManager.bindResource(heldKeysResource, held);
            TransactionSynchronizationManager.registerSynchronization(held);
        }
        if (held.closed) throw new IllegalStateException("A completed transaction cannot own an inventory mutex");
        held.keys.add(key.canonical());
    }

    private final class HeldKeys implements TransactionSynchronization {
        private final Set<String> keys = new HashSet<>();
        private boolean closed;

        @Override public int getOrder() { return Ordered.HIGHEST_PRECEDENCE; }

        @Override public void suspend() {
            if (TransactionSynchronizationManager.getResource(heldKeysResource) == this) {
                TransactionSynchronizationManager.unbindResource(heldKeysResource);
            }
        }

        @Override public void resume() {
            if (!closed) TransactionSynchronizationManager.bindResource(heldKeysResource, this);
        }

        @Override public void afterCommit() {
            // JDBC resources may still be bound while other afterCommit hooks
            // run, but PostgreSQL has already released transaction locks.
            closed = true;
            keys.clear();
        }

        @Override public void afterCompletion(int status) {
            closed = true;
            keys.clear();
            if (TransactionSynchronizationManager.getResource(heldKeysResource) == this) {
                TransactionSynchronizationManager.unbindResource(heldKeysResource);
            }
        }
    }
}
