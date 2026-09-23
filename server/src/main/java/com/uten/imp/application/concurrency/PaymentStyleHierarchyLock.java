package com.uten.imp.application.concurrency;

import jakarta.persistence.EntityManager;

/**
 * Transaction-scoped lock shared by payment-style hierarchy changes and referencing writes.
 *
 * <p>This is an application concurrency primitive, not payment-style domain behavior. Keeping it in
 * the application foundation lets independent features share one PostgreSQL advisory-lock key
 * without importing the master-data feature.
 *
 * <p>Referencing writes (receipts, GL entries, expenses, accounts, assets ...) only need the
 * hierarchy to stay still while they validate a style, so they take the key in <b>shared</b> mode
 * and never queue on each other. Hierarchy/status changes take it <b>exclusively</b> and wait for
 * every in-flight reference (V650 moved the database reference guards to the same shared mode).
 */
public final class PaymentStyleHierarchyLock {

    private static final String REFERENCE_LOCK_SQL =
            "SELECT pg_advisory_xact_lock_shared(hashtextextended('PAYMENT_STYLE_HIERARCHY',0))";
    private static final String HIERARCHY_CHANGE_LOCK_SQL =
            "SELECT pg_advisory_xact_lock(hashtextextended('PAYMENT_STYLE_HIERARCHY',0))";

    private PaymentStyleHierarchyLock() {
    }

    /** Referencing write: validate and store payment-style references under a shared lock. */
    public static void lock(EntityManager entityManager) {
        entityManager.createNativeQuery(REFERENCE_LOCK_SQL).getSingleResult();
    }

    /** Hierarchy or status change of payment styles: waits for, and blocks, every referencing write. */
    public static void lockForHierarchyChange(EntityManager entityManager) {
        entityManager.createNativeQuery(HIERARCHY_CHANGE_LOCK_SQL).getSingleResult();
    }
}
