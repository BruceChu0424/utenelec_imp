package com.uten.imp.application.concurrency;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.SQLException;
import java.time.Duration;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.*;

/** Isolated PostgreSQL mechanics: business SQL/rollback plus the unbounded deferred-COMMIT boundary. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class FulfillmentCommandDeadlinePostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    private static DriverManagerDataSource dataSource;
    private static JdbcTemplate jdbc;

    @BeforeAll
    static void start() {
        POSTGRES.start();
        dataSource = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        jdbc.execute("CREATE TABLE deadline_evidence(id uuid PRIMARY KEY, delay_seconds numeric NOT NULL)");
        jdbc.execute("""
                CREATE FUNCTION delay_evidence_commit() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF NEW.delay_seconds > 0 THEN PERFORM pg_sleep(NEW.delay_seconds); END IF;
                    RETURN NEW;
                END $$
                """);
        jdbc.execute("""
                CREATE CONSTRAINT TRIGGER deadline_evidence_commit AFTER INSERT ON deadline_evidence
                DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION delay_evidence_commit()
                """);
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void longBusinessStatementUsesTheRemainingCommandBudgetAndRollsBack() {
        UUID id = UUID.randomUUID();
        var manager = manager(dataSource);
        var transaction = new TransactionTemplate(manager);
        RuntimeException failure = assertTimeoutPreemptively(Duration.ofSeconds(8), () -> {
            try (var ignored = FulfillmentCommandDeadline.open(Duration.ofSeconds(1), System::nanoTime)) {
                return assertThrows(RuntimeException.class, () -> transaction.executeWithoutResult(status -> {
                    jdbc.execute("SET LOCAL statement_timeout = '60s'");
                    jdbc.update("INSERT INTO deadline_evidence VALUES (?, 0)", id);
                    jdbc.execute("SELECT pg_sleep(3)");
                }));
            }
        });
        assertTrue(hasSqlState(failure, "57014"), "业务SQL应按剩余时限取消, 并撤销之前的INSERT");
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM deadline_evidence WHERE id=?", Integer.class, id));
    }

    @Test
    void businessStatementNeverWidensAnExistingShorterServerTimeout() throws SQLException {
        UUID id = UUID.randomUUID();
        try (var connection = dataSource.getConnection()) {
            var single = new SingleConnectionDataSource(connection, true);
            var sameConnection = new JdbcTemplate(single);
            sameConnection.execute("SET statement_timeout = '200ms'");
            var transaction = new TransactionTemplate(manager(single));
            RuntimeException failure;
            try (var ignored = FulfillmentCommandDeadline.open(Duration.ofSeconds(5), System::nanoTime)) {
                failure = assertThrows(RuntimeException.class, () -> transaction.executeWithoutResult(status -> {
                    sameConnection.update("INSERT INTO deadline_evidence VALUES (?, 0)", id);
                    sameConnection.execute("SELECT pg_sleep(1)");
                }));
            }
            assertTrue(hasSqlState(failure, "57014"));
            assertEquals("200ms", sameConnection.queryForObject("SHOW statement_timeout", String.class));
        }
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM deadline_evidence WHERE id=?", Integer.class, id));
    }

    @Test
    void shorterExplicitTransactionTimeoutAlsoBoundsBusinessSql() {
        UUID id = UUID.randomUUID();
        var transaction = new TransactionTemplate(manager(dataSource));
        transaction.setTimeout(1);
        RuntimeException failure = assertTimeoutPreemptively(Duration.ofSeconds(8), () -> {
            try (var ignored = FulfillmentCommandDeadline.open(Duration.ofSeconds(5), System::nanoTime)) {
                return assertThrows(RuntimeException.class, () -> transaction.executeWithoutResult(status -> {
                    jdbc.execute("SET LOCAL statement_timeout = '60s'");
                    jdbc.update("INSERT INTO deadline_evidence VALUES (?, 0)", id);
                    jdbc.execute("SELECT pg_sleep(3)");
                }));
            }
        });
        assertTrue(hasSqlState(failure, "57014"));
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM deadline_evidence WHERE id=?", Integer.class, id));
    }

    @Test
    void cpuDeadlineBeforeCommitRollsBackAnActuallyInsertedRow() {
        UUID id = UUID.randomUUID();
        AtomicLong clock = new AtomicLong();
        var transaction = new TransactionTemplate(manager(dataSource));
        try (var ignored = FulfillmentCommandDeadline.open(Duration.ofSeconds(1), clock::get)) {
            assertThrows(FulfillmentCommandDeadline.BeforeCommitTimeout.class,
                    () -> transaction.executeWithoutResult(status -> {
                        jdbc.update("INSERT INTO deadline_evidence VALUES (?, 0)", id);
                        clock.addAndGet(TimeUnit.SECONDS.toNanos(2));
                    }));
        }
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM deadline_evidence WHERE id=?", Integer.class, id));
    }

    @Test
    void deferredCommitCanOutliveTheBudgetWithoutFalselyReportingRollback() {
        UUID id = UUID.randomUUID();
        var transaction = new TransactionTemplate(manager(dataSource));
        long started = System.nanoTime();
        try (var ignored = FulfillmentCommandDeadline.open(Duration.ofSeconds(1), System::nanoTime)) {
            // PG16 disables statement_timeout before CommitTransactionCommand.
            // Retain this explicit limitation: a completed COMMIT is success,
            // even when its deferred work took longer than the command budget.
            assertDoesNotThrow(() -> transaction.executeWithoutResult(status -> {
                jdbc.execute("SET LOCAL statement_timeout = '200ms'");
                jdbc.update("INSERT INTO deadline_evidence VALUES (?, 2)", id);
            }));
        }
        assertTrue(System.nanoTime() - started >= TimeUnit.SECONDS.toNanos(2));
        assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM deadline_evidence WHERE id=?", Integer.class, id),
                "不能把已提交的慢COMMIT冒充超时回滚; 后续必须专项减少提交工作量");
    }

    @Test
    void successfulCommitRestoresTheConnectionSettingForItsNextBorrower() throws SQLException {
        UUID id = UUID.randomUUID();
        try (var connection = dataSource.getConnection()) {
            var single = new SingleConnectionDataSource(connection, true);
            var sameConnection = new JdbcTemplate(single);
            sameConnection.execute("SET statement_timeout = '60s'");
            String original = sameConnection.queryForObject("SHOW statement_timeout", String.class);
            var transaction = new TransactionTemplate(manager(single));
            try (var ignored = FulfillmentCommandDeadline.open(Duration.ofSeconds(2), System::nanoTime)) {
                transaction.executeWithoutResult(status ->
                        sameConnection.update("INSERT INTO deadline_evidence VALUES (?, 0)", id));
            }
            assertEquals(original, sameConnection.queryForObject("SHOW statement_timeout", String.class));
        }
        assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM deadline_evidence WHERE id=?", Integer.class, id));
    }

    @Test
    void independentAfterCommitWorkDoesNotInheritTheCompletedCommandDeadline() {
        UUID first = UUID.randomUUID();
        UUID after = UUID.randomUUID();
        AtomicLong clock = new AtomicLong();
        var manager = manager(dataSource);
        var transaction = new TransactionTemplate(manager);
        var independent = new TransactionTemplate(manager);
        independent.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        independent.setTimeout(120);
        try (var ignored = FulfillmentCommandDeadline.open(Duration.ofSeconds(1), clock::get)) {
            transaction.executeWithoutResult(status -> {
                jdbc.update("INSERT INTO deadline_evidence VALUES (?, 0)", first);
                TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                    @Override public void afterCommit() {
                        clock.addAndGet(TimeUnit.SECONDS.toNanos(10));
                        assertNull(FulfillmentCommandDeadline.current());
                        independent.executeWithoutResult(other ->
                                jdbc.update("INSERT INTO deadline_evidence VALUES (?, 0)", after));
                    }
                });
            });
        }
        assertEquals(2, jdbc.queryForObject("SELECT count(*) FROM deadline_evidence WHERE id IN (?,?)",
                Integer.class, first, after));
    }

    @Test
    void nestedIndependentCommitCannotClearTheOuterDeadline() {
        UUID outer = UUID.randomUUID();
        UUID inner = UUID.randomUUID();
        AtomicLong clock = new AtomicLong();
        var manager = manager(dataSource);
        var transaction = new TransactionTemplate(manager);
        var independent = new TransactionTemplate(manager);
        independent.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        try (var ignored = FulfillmentCommandDeadline.open(Duration.ofSeconds(1), clock::get)) {
            assertThrows(FulfillmentCommandDeadline.BeforeCommitTimeout.class,
                    () -> transaction.executeWithoutResult(status -> {
                        jdbc.update("INSERT INTO deadline_evidence VALUES (?, 0)", outer);
                        independent.executeWithoutResult(other ->
                                jdbc.update("INSERT INTO deadline_evidence VALUES (?, 0)", inner));
                        assertNotNull(FulfillmentCommandDeadline.current());
                        clock.addAndGet(TimeUnit.SECONDS.toNanos(2));
                    }));
        }
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM deadline_evidence WHERE id=?", Integer.class, outer));
        assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM deadline_evidence WHERE id=?", Integer.class, inner),
                "保留既有REQUIRES_NEW独立提交语义, 不伪装成与外层一起回滚");
    }

    private static DataSourceTransactionManager manager(javax.sql.DataSource source) {
        var manager = new DataSourceTransactionManager(source);
        manager.setDefaultTimeout(40);
        manager.setTransactionExecutionListeners(List.of(new FulfillmentCommandDeadlineTransactions()));
        return manager;
    }

    private static boolean hasSqlState(Throwable failure, String state) {
        for (Throwable cause = failure; cause != null; cause = cause.getCause()) {
            if (cause instanceof SQLException sql && state.equals(sql.getSQLState())) return true;
        }
        return false;
    }
}
