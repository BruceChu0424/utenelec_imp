package com.uten.imp.application.concurrency;

import jakarta.persistence.EntityManager;

/**
 * Transaction-scoped serialization lock shared by payment-style hierarchy and referencing writes.
 *
 * <p>This is an application concurrency primitive, not payment-style domain behavior. Keeping it in
 * the application foundation lets independent features share one PostgreSQL advisory-lock key
 * without importing the master-data feature.
 */
public final class PaymentStyleHierarchyLock {

    private static final String LOCK_SQL =
            "SELECT pg_advisory_xact_lock(hashtextextended('PAYMENT_STYLE_HIERARCHY',0))";

    private PaymentStyleHierarchyLock() {
    }

    public static void lock(EntityManager entityManager) {
        entityManager.createNativeQuery(LOCK_SQL).getSingleResult();
    }
}
