package com.uten.imp.support;

import jakarta.persistence.EntityManager;
import org.hibernate.Session;
import org.springframework.orm.jpa.vendor.HibernateJpaDialect;
import org.springframework.transaction.SavepointManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.TransactionSystemException;

import java.sql.Connection;
import java.sql.Savepoint;
import java.sql.SQLException;

/** Test-only native-SQL harness: real JDBC savepoints with Spring synchronization callbacks. */
public final class NativeSavepointJpaDialect extends HibernateJpaDialect {
    @Override public Object beginTransaction(EntityManager em, TransactionDefinition definition) throws SQLException {
        Object delegate = super.beginTransaction(em, definition);
        return new NativeSavepoints(delegate, em.unwrap(Session.class).doReturningWork(connection -> connection));
    }

    @Override public void cleanupTransaction(Object data) {
        super.cleanupTransaction(data instanceof NativeSavepoints nativeData ? nativeData.delegate() : data);
    }

    private record NativeSavepoints(Object delegate, Connection connection) implements SavepointManager {
        @Override public Object createSavepoint() {
            try { return connection.setSavepoint(); }
            catch (SQLException failure) { throw new TransactionSystemException("Cannot create native test savepoint", failure); }
        }
        @Override public void rollbackToSavepoint(Object savepoint) {
            try { connection.rollback((Savepoint) savepoint); }
            catch (SQLException failure) { throw new TransactionSystemException("Cannot roll back native test savepoint", failure); }
        }
        @Override public void releaseSavepoint(Object savepoint) {
            try { connection.releaseSavepoint((Savepoint) savepoint); }
            catch (SQLException failure) { throw new TransactionSystemException("Cannot release native test savepoint", failure); }
        }
    }
}
