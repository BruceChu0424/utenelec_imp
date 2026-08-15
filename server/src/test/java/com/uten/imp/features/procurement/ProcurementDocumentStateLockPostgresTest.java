package com.uten.imp.features.procurement;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.time.Duration;
import java.time.LocalDate;
import java.util.UUID;
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
 * Real PostgreSQL proof for the document-header lock used by procurement and
 * subcontract state transitions. The second transaction must read the status
 * committed by the first transaction after waiting on {@code FOR UPDATE}.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementDocumentStateLockPostgresTest {

    private static final java.util.concurrent.atomic.AtomicInteger BUSINESS_IDENTIFIER_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();

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
    void competingApprovalsSerializeAndOnlyOneMayPostSideEffects() {
        assertTimeoutPreemptively(Duration.ofSeconds(15), () -> {
            UUID requestId = prepareDraftRequest();
            CountDownLatch firstHasHeaderLock = new CountDownLatch(1);
            CountDownLatch allowFirstCommit = new CountDownLatch(1);
            CountDownLatch secondReachedLock = new CountDownLatch(1);
            CountDownLatch secondAcquiredLock = new CountDownLatch(1);

            try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
                Future<Boolean> first = executor.submit(() ->
                        approveFirst(
                                requestId,
                                firstHasHeaderLock,
                                allowFirstCommit));

                assertTrue(firstHasHeaderLock.await(5, TimeUnit.SECONDS));

                Future<Boolean> second = executor.submit(() ->
                        approveSecond(
                                requestId,
                                secondReachedLock,
                                secondAcquiredLock));

                assertTrue(secondReachedLock.await(5, TimeUnit.SECONDS));
                assertFalse(
                        secondAcquiredLock.await(500, TimeUnit.MILLISECONDS),
                        "the second approval must wait for the document header lock");

                allowFirstCommit.countDown();
                assertTrue(first.get(5, TimeUnit.SECONDS));
                assertFalse(
                        second.get(5, TimeUnit.SECONDS),
                        "the second approval must see status=approved and skip posting");
            } finally {
                allowFirstCommit.countDown();
            }

            try (Connection connection = connection();
                 PreparedStatement status = connection.prepareStatement(
                         "select status from purchase_requests where id = ?");
                 PreparedStatement postings = connection.prepareStatement(
                         "select count(*) from tx_test_procurement_postings where source_id = ?")) {
                status.setObject(1, requestId);
                postings.setObject(1, requestId);
                assertEquals(1, scalarInt(status));
                assertEquals(1, scalarInt(postings));
            }
        });
    }

    private static UUID prepareDraftRequest() throws Exception {
        UUID id = UUID.randomUUID();
        try (Connection connection = connection();
             Statement schema = connection.createStatement();
             PreparedStatement insert = connection.prepareStatement("""
                     insert into purchase_requests(id, bill_no, bill_date, status)
                     values (?, ?, ?, 0)
                     """)) {
            schema.execute("drop table if exists tx_test_procurement_postings");
            schema.execute("""
                    create table tx_test_procurement_postings (
                        id bigserial primary key,
                        source_id uuid not null
                    )
                    """);
            insert.setObject(1, id);
            LocalDate billDate = LocalDate.of(2026, 7, 31);
            insert.setString(2, businessIdentifier("CS", billDate));
            insert.setObject(3, billDate);
            insert.executeUpdate();
        }
        return id;
    }

    private static String businessIdentifier(String prefix, LocalDate date) {
        int sequence = BUSINESS_IDENTIFIER_SEQUENCE.incrementAndGet();
        if (sequence > 999_999) {
            throw new IllegalStateException("test business identifier sequence exhausted");
        }
        return prefix + date.toString().replace("-", "") + "%06d".formatted(sequence);
    }

    private static boolean approveFirst(
            UUID requestId,
            CountDownLatch firstHasHeaderLock,
            CountDownLatch allowFirstCommit) throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                assertEquals(0, lockStatus(connection, requestId));
                firstHasHeaderLock.countDown();
                assertTrue(allowFirstCommit.await(5, TimeUnit.SECONDS));
                recordPosting(connection, requestId);
                updateApproved(connection, requestId);
                connection.commit();
                return true;
            } catch (Throwable error) {
                connection.rollback();
                firstHasHeaderLock.countDown();
                throw error;
            }
        }
    }

    private static boolean approveSecond(
            UUID requestId,
            CountDownLatch secondReachedLock,
            CountDownLatch secondAcquiredLock) throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                secondReachedLock.countDown();
                int status = lockStatus(connection, requestId);
                secondAcquiredLock.countDown();
                if (status != 0) {
                    connection.commit();
                    return false;
                }
                recordPosting(connection, requestId);
                updateApproved(connection, requestId);
                connection.commit();
                return true;
            } catch (Throwable error) {
                connection.rollback();
                throw error;
            }
        }
    }

    private static int lockStatus(Connection connection, UUID requestId)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                select status
                from purchase_requests
                where id = ?
                for update
                """)) {
            statement.setObject(1, requestId);
            return scalarInt(statement);
        }
    }

    private static void recordPosting(Connection connection, UUID requestId)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                insert into tx_test_procurement_postings(source_id)
                values (?)
                """)) {
            statement.setObject(1, requestId);
            statement.executeUpdate();
        }
    }

    private static void updateApproved(Connection connection, UUID requestId)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                update purchase_requests
                set status = 1
                where id = ?
                """)) {
            statement.setObject(1, requestId);
            assertEquals(1, statement.executeUpdate());
        }
    }

    private static int scalarInt(PreparedStatement statement) throws Exception {
        try (ResultSet result = statement.executeQuery()) {
            assertTrue(result.next());
            return result.getInt(1);
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }
}
