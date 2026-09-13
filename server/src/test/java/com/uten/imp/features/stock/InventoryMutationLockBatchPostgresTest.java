package com.uten.imp.features.stock;

import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.hibernate.Session;
import org.hibernate.SessionFactory;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Properties;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.*;

/** Same PostgreSQL lock keys/order/transactions, with bounded JDBC round trips. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class InventoryMutationLockBatchPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    private static EntityManagerFactory factory;
    private static EntityManager em;
    private static JdbcTemplate jdbc;
    private static TransactionTemplate transactions;
    private static InventoryMutationLock locks;

    @BeforeAll static void start() {
        POSTGRES.start();
        var source = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        jdbc = new JdbcTemplate(source);
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(source);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.features.sales.order");
        var properties = new Properties();
        properties.setProperty("hibernate.hbm2ddl.auto", "none");
        properties.setProperty("hibernate.generate_statistics", "true");
        bean.setJpaProperties(properties);
        bean.afterPropertiesSet();
        factory = bean.getObject();
        em = SharedEntityManagerCreator.createSharedEntityManager(factory);
        transactions = new TransactionTemplate(new JpaTransactionManager(factory));
        locks = new InventoryMutationLock(em);
    }

    @AfterAll static void close() {
        if (factory != null) factory.close();
        POSTGRES.stop();
    }

    @Test void aThousandDistinctKeysUseThreeStatementsAndStillReallyReacquire() {
        List<InventoryKey> distinct = java.util.stream.IntStream.range(0, 1001)
                .mapToObj(i -> new InventoryKey(UUID.randomUUID(), i % 2 == 0 ? null : UUID.randomUUID())).toList();
        var input = new ArrayList<>(distinct);
        input.addAll(distinct.subList(0, 50));
        Collections.reverse(input);
        transactions.executeWithoutResult(status -> {
            var statistics = factory.unwrap(SessionFactory.class).getStatistics();
            long before = statistics.getPrepareStatementCount();
            locks.lockAll(input);
            assertEquals(3, statistics.getPrepareStatementCount() - before);
            distinct.forEach(locks::requireHeld);
            assertEquals(1001, ((Number) em.createNativeQuery("""
                    SELECT count(*) FROM pg_locks
                    WHERE pid=pg_backend_pid() AND locktype='advisory' AND granted
                    """).getSingleResult()).intValue());
            long second = statistics.getPrepareStatementCount();
            locks.lockAll(input);
            assertEquals(3, statistics.getPrepareStatementCount() - second,
                    "Remembered ownership must not replace actual transaction-lock acquisition");
        });
    }

    @Test void reversedInputWaitsAtTheLowestKeyBeforeTakingHigherKeys() throws Exception {
        var keys = java.util.stream.IntStream.range(0, 3)
                .mapToObj(i -> new InventoryKey(UUID.randomUUID(), null)).sorted().toList();
        var reversed = new ArrayList<>(keys);
        Collections.reverse(reversed);
        var attempting = new CountDownLatch(1);
        var acquired = new CountDownLatch(1);
        var release = new CountDownLatch(1);
        var pid = new AtomicInteger();
        try (Connection blocker = independent(); Connection observer = independent();
             var workers = Executors.newSingleThreadExecutor()) {
            assertTrue(tryLock(blocker, keys.getFirst()));
            var task = workers.submit(() -> transactions.executeWithoutResult(status -> {
                pid.set(((Number) em.createNativeQuery("SELECT pg_backend_pid()").getSingleResult()).intValue());
                attempting.countDown();
                locks.lockAll(reversed);
                keys.forEach(locks::requireHeld);
                acquired.countDown();
                await(release);
            }));
            try {
                assertTrue(attempting.await(5, TimeUnit.SECONDS));
                waitForDatabaseLock(pid.get());
                assertTrue(tryLock(observer, keys.get(1)), "Higher key must not be held while waiting for the first");
                assertTrue(tryLock(observer, keys.get(2)));
                observer.rollback();
                blocker.commit();
                assertTrue(acquired.await(5, TimeUnit.SECONDS));
                for (var key : keys) assertFalse(tryLock(observer, key), "Every key must be held after batch completion");
            } finally {
                observer.rollback(); blocker.rollback(); release.countDown();
            }
            task.get(5, TimeUnit.SECONDS);
        }
    }

    @Test void savepointRollbackCannotTurnJavaBookkeepingIntoAFalseLockCache() throws Exception {
        var key = new InventoryKey(UUID.randomUUID(), UUID.randomUUID());
        var rolledBack = new CountDownLatch(1);
        var otherHolds = new CountDownLatch(1);
        var attempting = new CountDownLatch(1);
        var pid = new AtomicInteger();
        try (Connection blocker = independent(); var workers = Executors.newSingleThreadExecutor()) {
            var task = workers.submit(() -> transactions.executeWithoutResult(status -> {
                pid.set(((Number) em.createNativeQuery("SELECT pg_backend_pid()").getSingleResult()).intValue());
                var savepoint = em.unwrap(Session.class).doReturningWork(Connection::setSavepoint);
                locks.lock(key);
                em.unwrap(Session.class).doWork(connection -> connection.rollback(savepoint));
                rolledBack.countDown();
                await(otherHolds);
                attempting.countDown();
                locks.lock(key);
                locks.requireHeld(key);
            }));
            try {
                assertTrue(rolledBack.await(5, TimeUnit.SECONDS));
                assertTrue(tryLock(blocker, key), "The savepoint rollback really released the original PostgreSQL lock");
                otherHolds.countDown();
                assertTrue(attempting.await(5, TimeUnit.SECONDS));
                waitForDatabaseLock(pid.get());
                assertFalse(task.isDone(), "The repeated call must reacquire, not trust the old Java proof");
            } finally {
                blocker.rollback(); otherHolds.countDown();
            }
            task.get(5, TimeUnit.SECONDS);
        }
    }

    private static Connection independent() throws Exception {
        var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        connection.setAutoCommit(false);
        return connection;
    }

    private static boolean tryLock(Connection connection, InventoryKey key) throws Exception {
        try (var statement = connection.prepareStatement("SELECT pg_try_advisory_xact_lock(hashtextextended(?,?))")) {
            statement.setString(1, key.canonical());
            statement.setLong(2, InventoryMutationLock.HASH_NAMESPACE);
            try (var rows = statement.executeQuery()) { assertTrue(rows.next()); return rows.getBoolean(1); }
        }
    }

    private static void waitForDatabaseLock(int pid) throws InterruptedException {
        long deadline = System.nanoTime() + Duration.ofSeconds(5).toNanos();
        while (System.nanoTime() < deadline) {
            if (Boolean.TRUE.equals(jdbc.queryForObject("""
                    SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid=? AND wait_event_type='Lock')
                    """, Boolean.class, pid))) return;
            Thread.sleep(10);
        }
        fail("Expected an actual PostgreSQL lock wait from backend " + pid);
    }

    private static void await(CountDownLatch latch) {
        try { assertTrue(latch.await(10, TimeUnit.SECONDS)); }
        catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new IllegalStateException(error); }
    }
}
