package com.uten.imp.features.stock;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real PostgreSQL rollback/savepoints for the handle contract, without the ERP migration fixture. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PreStockedInboundBatchScopePostgresTest {
    private static final PostgreSQLContainer<?> DATABASE = new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate db;
    private static TransactionTemplate transactions;

    @BeforeAll static void start() {
        DATABASE.start();
        var source = new DriverManagerDataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword());
        db = new JdbcTemplate(source);
        transactions = new TransactionTemplate(new DataSourceTransactionManager(source));
        db.execute("CREATE TABLE batch_scope_facts(id uuid PRIMARY KEY, batch_id uuid NOT NULL)");
    }

    @AfterAll static void stop() { DATABASE.stop(); }

    @Test void swallowingAPartlyWrittenConfirmationStillRollsBackTheWholeBatch() {
        UUID batchId = UUID.randomUUID(), first = UUID.randomUUID(), rejected = UUID.randomUUID();
        List<UUID> posted = new ArrayList<>();
        List<List<UUID>> finishes = new ArrayList<>();
        transactions.executeWithoutResult(owner -> {
            assertThrows(IllegalStateException.class, () -> PreStockedInboundBatchScope.run(posted, new HashSet<>(),
                    (id, key) -> {
                        db.update("INSERT INTO batch_scope_facts VALUES (?,?)", id, batchId);
                        posted.add(id);
                        if (id.equals(rejected)) throw new IllegalArgumentException("failed after insert");
                    }, finishes::add, owner::setRollbackOnly, batch -> {
                        batch.confirm(first, "first");
                        assertThrows(IllegalArgumentException.class, () -> batch.confirm(rejected, "rejected"));
                    }));
            assertTrue(owner.isRollbackOnly(), "即使两层异常都被调用方捕获, 事务也不能提交");
        });
        assertTrue(finishes.isEmpty());
        assertEquals(0, count(batchId));
    }

    @Test void ordinarySavepointRollbackRestoresFactsAndBatchProjectionInputs() {
        UUID batchId = UUID.randomUUID(), first = UUID.randomUUID(), undone = UUID.randomUUID(), last = UUID.randomUUID();
        List<UUID> posted = new ArrayList<>();
        HashSet<UUID> warehouses = new HashSet<>();
        List<List<UUID>> finishes = new ArrayList<>();
        transactions.executeWithoutResult(owner -> PreStockedInboundBatchScope.run(posted, warehouses,
                (id, key) -> {
                    db.update("INSERT INTO batch_scope_facts VALUES (?,?)", id, batchId);
                    posted.add(id); warehouses.add(id);
                }, finishes::add, owner::setRollbackOnly, batch -> {
                    batch.confirm(first, "first");
                    Object savepoint = owner.createSavepoint();
                    batch.confirm(undone, "undone");
                    owner.rollbackToSavepoint(savepoint);
                    owner.releaseSavepoint(savepoint);
                    assertEquals(List.of(first), posted);
                    assertFalse(warehouses.contains(undone));
                    batch.confirm(last, "last");
                }));
        assertEquals(List.of(List.of(first, last)), finishes);
        assertEquals(2, count(batchId));
        assertEquals(0, db.queryForObject("SELECT count(*) FROM batch_scope_facts WHERE id=?", Integer.class, undone));
    }

    @Test void rollbackToSavepointCannotUnpoisonAFailedConfirmation() {
        UUID batchId = UUID.randomUUID(), first = UUID.randomUUID(), rejected = UUID.randomUUID();
        List<UUID> posted = new ArrayList<>();
        transactions.executeWithoutResult(owner -> assertThrows(IllegalStateException.class,
                () -> PreStockedInboundBatchScope.run(posted, new HashSet<>(), (id, key) -> {
                    db.update("INSERT INTO batch_scope_facts VALUES (?,?)", id, batchId);
                    posted.add(id);
                    if (id.equals(rejected)) throw new IllegalArgumentException("failed after insert");
                }, ids -> fail("failed batch must not finish"), owner::setRollbackOnly, batch -> {
                    batch.confirm(first, "first");
                    Object savepoint = owner.createSavepoint();
                    assertThrows(IllegalArgumentException.class, () -> batch.confirm(rejected, "rejected"));
                    owner.rollbackToSavepoint(savepoint);
                    assertTrue(owner.isRollbackOnly());
                })));
        assertEquals(0, count(batchId));
    }

    private int count(UUID batch) {
        return db.queryForObject("SELECT count(*) FROM batch_scope_facts WHERE batch_id=?", Integer.class, batch);
    }
}
