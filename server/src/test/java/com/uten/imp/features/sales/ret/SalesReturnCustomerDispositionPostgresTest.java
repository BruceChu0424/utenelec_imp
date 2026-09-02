package com.uten.imp.features.sales.ret;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.time.LocalDate;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Real PostgreSQL proof for V219 customer-disposition authority + append-only events.
 *
 * <p>Pins the DB-level invariants the service relies on: the disposition CHECK constraints,
 * the DECIDED completeness invariant, the fulfilment_reopened↔RESHIP/EXCHANGE coupling, and the
 * append-only guard on {@code sales_return_disposition_events}. Service-level re-reserve / flag
 * behaviour is exercised by the migration + constraint suite plus code review.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SalesReturnCustomerDispositionPostgresTest {

    private static final java.util.concurrent.atomic.AtomicInteger BUSINESS_IDENTIFIER_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();
    private static final java.util.concurrent.atomic.AtomicInteger CLIENT_CODE_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger(900_000);

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void newReturnDefaultsToPendingDisposition() throws Exception {
        UUID clientId = UUID.randomUUID();
        UUID returnId = UUID.randomUUID();
        try (Connection c = connection()) {
            insertClient(c, clientId);
            insertReturn(c, returnId, clientId, null, "PENDING_DEFAULT");
            try (PreparedStatement q = c.prepareStatement(
                    "SELECT customer_disposition, disposition_status, fulfilment_reopened "
                            + "FROM sales_returns WHERE id = ?")) {
                q.setObject(1, returnId);
                try (var rs = q.executeQuery()) {
                    assertTrue(rs.next());
                    assertNull(rs.getString(1));
                    assertEquals("PENDING", rs.getString(2));
                    assertFalse(rs.getBoolean(3));
                }
            }
        }
    }

    @Test
    void unknownDispositionRejected() throws Exception {
        UUID clientId = UUID.randomUUID();
        try (Connection c = connection()) {
            insertClient(c, clientId);
            SQLException ex = assertThrows(SQLException.class, () -> insertReturn(
                    c, UUID.randomUUID(), clientId, "BOGUS", "BAD-DISP"));
            assertEquals("23514", ex.getSQLState());
        }
    }

    @Test
    void decidedWithoutApproverOrTimestampRejected() throws Exception {
        UUID clientId = UUID.randomUUID();
        try (Connection c = connection()) {
            insertClient(c, clientId);
            // DECIDED but missing decided_by / decided_at → invariant violation.
            try (PreparedStatement s = c.prepareStatement("""
                    INSERT INTO sales_returns (id, bill_no, bill_date, client_id, status,
                        customer_disposition, disposition_status)
                    VALUES (?, ?, ?, ?, 1, 'REFUND_CLOSED', 'DECIDED')
                    """)) {
                s.setObject(1, UUID.randomUUID());
                s.setString(2, businessIdentifier("XT", LocalDate.of(2026, 8, 6)));
                s.setObject(3, LocalDate.of(2026, 8, 6));
                s.setObject(4, clientId);
                SQLException ex = assertThrows(SQLException.class, s::executeUpdate);
                assertEquals("23514", ex.getSQLState());
            }
        }
    }

    @Test
    void fulfilmentReopenedOnlyAllowedForReshipOrExchange() throws Exception {
        UUID clientId = UUID.randomUUID();
        try (Connection c = connection()) {
            insertClient(c, clientId);
            // REFUND_CLOSED + fulfilment_reopened=true → violation.
            try (PreparedStatement s = c.prepareStatement("""
                    INSERT INTO sales_returns (id, bill_no, bill_date, client_id, status,
                        customer_disposition, disposition_status, disposition_decided_by,
                        disposition_decided_at, fulfilment_reopened)
                    VALUES (?, ?, ?, ?, 1, 'REFUND_CLOSED', 'DECIDED', ?,
                        now(), TRUE)
                    """)) {
                s.setObject(1, UUID.randomUUID());
                s.setString(2, businessIdentifier("XT", LocalDate.of(2026, 8, 6)));
                s.setObject(3, LocalDate.of(2026, 8, 6));
                s.setObject(4, clientId);
                s.setObject(5, UUID.randomUUID());
                SQLException ex = assertThrows(SQLException.class, s::executeUpdate);
                assertEquals("23514", ex.getSQLState());
            }
        }
    }

    @Test
    void validDecidedDispositionPersists() throws Exception {
        UUID clientId = UUID.randomUUID();
        UUID approver = UUID.randomUUID();
        UUID returnId = UUID.randomUUID();
        try (Connection c = connection()) {
            insertClient(c, clientId);
            try (PreparedStatement s = c.prepareStatement("""
                    INSERT INTO sales_returns (id, bill_no, bill_date, client_id, status,
                        customer_disposition, disposition_status, disposition_decided_by,
                        disposition_decided_at, disposition_reason, fulfilment_reopened)
                    VALUES (?, ?, ?, ?, 1, 'RESHIP', 'DECIDED', ?, now(), ?, TRUE)
                    """)) {
                s.setObject(1, returnId);
                s.setString(2, businessIdentifier("XT", LocalDate.of(2026, 8, 6)));
                s.setObject(3, LocalDate.of(2026, 8, 6));
                s.setObject(4, clientId);
                s.setObject(5, approver);
                s.setString(6, "customer approved replacement shipment");
                assertEquals(1, s.executeUpdate());
            }
        }
    }

    @Test
    void dispositionEventsAreAppendOnly() throws Exception {
        UUID clientId = UUID.randomUUID();
        UUID returnId = UUID.randomUUID();
        UUID eventId = UUID.randomUUID();
        try (Connection c = connection()) {
            insertClient(c, clientId);
            insertDecidedReturn(c, returnId, clientId, "REFUND_CLOSED");
            try (PreparedStatement s = c.prepareStatement("""
                    INSERT INTO sales_return_disposition_events (
                        id, return_id, action, disposition, reason, actor_employee_id, occurred_at)
                    VALUES (?, ?, 'DISPOSITION_DECIDED', 'REFUND_CLOSED', ?, ?, now())
                    """)) {
                s.setObject(1, eventId);
                s.setObject(2, returnId);
                s.setString(3, "refund finalized");
                s.setObject(4, UUID.randomUUID());
                assertEquals(1, s.executeUpdate());
            }
            // UPDATE must be rejected (append-only).
            try (PreparedStatement u = c.prepareStatement(
                    "UPDATE sales_return_disposition_events SET reason = 'tampered' WHERE id = ?")) {
                u.setObject(1, eventId);
                SQLException ex = assertThrows(SQLException.class, u::executeUpdate);
                assertEquals("55000", ex.getSQLState());
                assertTrue(ex.getMessage().contains("append-only"));
            }
            // DELETE must be rejected (append-only).
            try (PreparedStatement d = c.prepareStatement(
                    "DELETE FROM sales_return_disposition_events WHERE id = ?")) {
                d.setObject(1, eventId);
                SQLException ex = assertThrows(SQLException.class, d::executeUpdate);
                assertEquals("55000", ex.getSQLState());
            }
            // The original event still reads back intact.
            try (PreparedStatement q = c.prepareStatement(
                    "SELECT reason FROM sales_return_disposition_events WHERE id = ?")) {
                q.setObject(1, eventId);
                try (var rs = q.executeQuery()) {
                    assertTrue(rs.next());
                    assertEquals("refund finalized", rs.getString(1));
                }
            }
        }
    }

    private static void insertClient(Connection c, UUID clientId) throws Exception {
        int codeSequence = CLIENT_CODE_SEQUENCE.incrementAndGet();
        try (PreparedStatement s = c.prepareStatement(
                "INSERT INTO clients(id, code, name, code_sequence, sales_payment_type) "
                        + "VALUES (?, ?, ?, ?, 'MONTHLY')")) {
            s.setObject(1, clientId);
            s.setString(2, "KH%06d".formatted(codeSequence));
            s.setString(3, "Disposition test client");
            s.setInt(4, codeSequence);
            assertEquals(1, s.executeUpdate());
        }
    }

    private static void insertReturn(Connection c, UUID returnId, UUID clientId,
                                     String disposition, String tag) throws Exception {
        try (PreparedStatement s = c.prepareStatement("""
                INSERT INTO sales_returns (id, bill_no, bill_date, client_id, status, customer_disposition)
                VALUES (?, ?, ?, ?, 1, ?)
                """)) {
            s.setObject(1, returnId);
            s.setString(2, businessIdentifier("XT", LocalDate.of(2026, 8, 6)));
            s.setObject(3, LocalDate.of(2026, 8, 6));
            s.setObject(4, clientId);
            s.setString(5, disposition);
            assertEquals(1, s.executeUpdate());
        }
    }

    private static void insertDecidedReturn(Connection c, UUID returnId, UUID clientId,
                                            String disposition) throws Exception {
        try (PreparedStatement s = c.prepareStatement("""
                INSERT INTO sales_returns (id, bill_no, bill_date, client_id, status,
                    customer_disposition, disposition_status, disposition_decided_by,
                    disposition_decided_at, disposition_reason)
                VALUES (?, ?, ?, ?, 1, ?, 'DECIDED', ?, now(), ?)
                """)) {
            s.setObject(1, returnId);
            s.setString(2, businessIdentifier("XT", LocalDate.of(2026, 8, 6)));
            s.setObject(3, LocalDate.of(2026, 8, 6));
            s.setObject(4, clientId);
            s.setString(5, disposition);
            s.setObject(6, UUID.randomUUID());
            s.setString(7, "decided for event test");
            assertEquals(1, s.executeUpdate());
        }
    }

    private static String businessIdentifier(String prefix, LocalDate date) {
        int sequence = BUSINESS_IDENTIFIER_SEQUENCE.incrementAndGet();
        if (sequence > 999_999) {
            throw new IllegalStateException("test business identifier sequence exhausted");
        }
        return prefix + date.toString().replace("-", "") + "%06d".formatted(sequence);
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
}
