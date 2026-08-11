package com.uten.imp.features.stock;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.Collection;
import java.util.List;

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

    private final EntityManager em;

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
        for (InventoryKey key : keys) {
            em.createNativeQuery("""
                            SELECT pg_advisory_xact_lock(
                                hashtextextended(CAST(:inventoryKey AS text), CAST(:namespace AS bigint))
                            )
                            """)
                    .setParameter("inventoryKey", key.canonical())
                    .setParameter("namespace", HASH_NAMESPACE)
                    .getSingleResult();
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void lock(InventoryKey key) {
        lockAll(List.of(key));
    }
}
