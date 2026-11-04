package com.uten.imp.application.concurrency;

import jakarta.persistence.EntityManager;
import org.springframework.jdbc.core.JdbcTemplate;

/** Pure transaction lock shared by metadata and native money writers; grants no extra read authority. */
public final class FinanceClassificationLock {
    private static final String SQL="SELECT pg_advisory_xact_lock(hashtextextended('uten:open-item-classification',0))";
    private FinanceClassificationLock() { }
    public static void lock(EntityManager em){em.createNativeQuery(SQL).getSingleResult();}
    public static void lock(JdbcTemplate db){db.query(SQL,rs->{});}
}
