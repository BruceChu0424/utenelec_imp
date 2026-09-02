package com.uten.imp.features.stock;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.time.Duration;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;

/**
 * Real PostgreSQL evidence for the inventory serialization primitive and the
 * database guards installed by V142.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class InventoryTransactionalIntegrityPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void installsPostingAndCumulativeQuantityGuards() throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            // V408 追加式账户流把对账唯一索引升级为含 entry_kind 的
            // uq_finance_reconciliation_active_source_account_kind。
            assertEquals(2, scalarLong(statement, """
                    select count(*)
                    from pg_indexes
                    where schemaname = 'public'
                      and indexname in (
                          'uq_arap_active_source',
                          'uq_finance_reconciliation_active_source_account_kind'
                      )
                    """));
            assertTrue(scalarBoolean(statement, """
                    select convalidated
                    from pg_constraint
                    where conname = 'accounts_balance_consistency_chk'
                    """));
            assertEquals(6, scalarLong(statement, """
                    select count(*)
                    from pg_trigger
                    where not tgisinternal
                      and tgname in (
                          'trg_production_plan_finished_guard',
                          'trg_production_plan_inbound_guard',
                          'trg_plan_order_link_produced_guard',
                          'trg_plan_order_link_inbound_guard',
                          'trg_purchase_request_ordered_guard',
                          'trg_subcontract_application_ordered_guard'
                      )
                    """));
        }
    }

    @Test
    void sameInventoryKeySerializesCompetingReservations() {
        assertTimeoutPreemptively(Duration.ofSeconds(15), () -> {
            prepareReservationFixture();

            CountDownLatch firstHasReserved = new CountDownLatch(1);
            CountDownLatch allowFirstCommit = new CountDownLatch(1);
            CountDownLatch secondReachedLock = new CountDownLatch(1);
            CountDownLatch secondAcquiredLock = new CountDownLatch(1);

            try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
                Future<Boolean> first = executor.submit(() -> {
                    try (Connection connection = connection()) {
                        connection.setAutoCommit(false);
                        try {
                            acquireInventoryLock(connection, "goods-a:color-a");
                            boolean inserted = reserveIfAvailable(
                                    connection, "goods-a:color-a", new BigDecimal("70"));
                            firstHasReserved.countDown();
                            assertTrue(allowFirstCommit.await(5, TimeUnit.SECONDS));
                            connection.commit();
                            return inserted;
                        } catch (Throwable error) {
                            connection.rollback();
                            firstHasReserved.countDown();
                            throw error;
                        }
                    }
                });

                assertTrue(firstHasReserved.await(5, TimeUnit.SECONDS));

                Future<Boolean> second = executor.submit(() -> {
                    try (Connection connection = connection()) {
                        connection.setAutoCommit(false);
                        try {
                            secondReachedLock.countDown();
                            acquireInventoryLock(connection, "goods-a:color-a");
                            secondAcquiredLock.countDown();
                            boolean inserted = reserveIfAvailable(
                                    connection, "goods-a:color-a", new BigDecimal("70"));
                            connection.commit();
                            return inserted;
                        } catch (Throwable error) {
                            connection.rollback();
                            throw error;
                        }
                    }
                });

                assertTrue(secondReachedLock.await(5, TimeUnit.SECONDS));
                assertFalse(
                        secondAcquiredLock.await(500, TimeUnit.MILLISECONDS),
                        "the competing transaction must wait for the first xact lock");

                allowFirstCommit.countDown();
                assertTrue(first.get(5, TimeUnit.SECONDS));
                assertFalse(second.get(5, TimeUnit.SECONDS));
            } finally {
                allowFirstCommit.countDown();
            }

            try (Connection connection = connection();
                 Statement statement = connection.createStatement()) {
                assertEquals(0, new BigDecimal("70").compareTo(
                        scalarDecimal(statement,
                                "select coalesce(sum(qty), 0) from tx_test_reservations")));
                assertTrue(scalarDecimal(statement, """
                        select s.stock_qty - coalesce(sum(r.qty), 0)
                        from tx_test_inventory s
                        left join tx_test_reservations r
                          on r.inventory_key = s.inventory_key
                        group by s.stock_qty
                        """).signum() >= 0);
            }
        });
    }

    private static void prepareReservationFixture() throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            statement.execute("drop table if exists tx_test_reservations");
            statement.execute("drop table if exists tx_test_inventory");
            statement.execute("""
                    create table tx_test_inventory (
                        inventory_key text primary key,
                        stock_qty numeric(18,4) not null
                    )
                    """);
            statement.execute("""
                    create table tx_test_reservations (
                        id bigserial primary key,
                        inventory_key text not null,
                        qty numeric(18,4) not null check (qty > 0)
                    )
                    """);
            statement.execute("""
                    insert into tx_test_inventory(inventory_key, stock_qty)
                    values ('goods-a:color-a', 100)
                    """);
        }
    }

    private static void acquireInventoryLock(Connection connection, String key)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                select pg_advisory_xact_lock(hashtextextended(?, ?))
                """)) {
            statement.setString(1, key);
            statement.setLong(2, InventoryMutationLock.HASH_NAMESPACE);
            statement.executeQuery().close();
        }
    }

    private static boolean reserveIfAvailable(
            Connection connection, String key, BigDecimal qty) throws Exception {
        BigDecimal available;
        try (PreparedStatement statement = connection.prepareStatement("""
                select s.stock_qty - coalesce((
                    select sum(r.qty)
                    from tx_test_reservations r
                    where r.inventory_key = s.inventory_key
                ), 0)
                from tx_test_inventory s
                where s.inventory_key = ?
                """)) {
            statement.setString(1, key);
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                available = result.getBigDecimal(1);
            }
        }
        if (available.compareTo(qty) < 0) {
            return false;
        }
        try (PreparedStatement statement = connection.prepareStatement("""
                insert into tx_test_reservations(inventory_key, qty)
                values (?, ?)
                """)) {
            statement.setString(1, key);
            statement.setBigDecimal(2, qty);
            statement.executeUpdate();
            return true;
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private static long scalarLong(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getLong(1);
        }
    }

    private static boolean scalarBoolean(Statement statement, String sql)
            throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getBoolean(1);
        }
    }

    private static BigDecimal scalarDecimal(Statement statement, String sql)
            throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getBigDecimal(1);
        }
    }
}
