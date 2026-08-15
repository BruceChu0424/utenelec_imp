package com.uten.imp.migration;

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
import java.sql.SQLException;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Non-empty rehearsal for snapshot migrations on tables with deferred triggers. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsHistorySnapshotDeferredTriggerPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void startPostgres() {
        POSTGRES.start();
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void v262AndV263FlushDeferredEventsBeforeTighteningColumns() throws Exception {
        flyway("261").migrate();

        UUID goodsId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID stockDocumentId = UUID.randomUUID();
        UUID stockItemId = UUID.randomUUID();
        UUID subcontractReceiptId = UUID.randomUUID();
        UUID subcontractReceiptItemId = UUID.randomUUID();
        UUID subcontractArrivalExceptionId = UUID.randomUUID();
        UUID reviewerEmployeeId = UUID.randomUUID();
        UUID reviewerUserId = UUID.randomUUID();
        try (Connection connection = connection()) {
            execute(connection, """
                    INSERT INTO goods (id, code, name, code_sequence)
                    VALUES (?, ?, 'deferred-trigger goods',
                            (SELECT COALESCE(max(code_sequence), 0) + 1 FROM goods))
                    """, goodsId, "SNAPSHOT-" + goodsId);
            execute(connection, """
                    INSERT INTO warehouses (id, code, name)
                    VALUES (?, ?, 'snapshot migration warehouse')
                    """, warehouseId, "SNAPSHOT-WH-" + warehouseId);
            execute(connection, """
                    INSERT INTO stock_documents (
                        id, doc_type, bill_no, bill_date, warehouse_id, status)
                    VALUES (?, 'OTHER_IN', ?, DATE '2026-08-14', ?, 1)
                    """, stockDocumentId, "SNAPSHOT-STOCK-" + stockDocumentId,
                    warehouseId);
            execute(connection, """
                    INSERT INTO stock_document_items (
                        id, doc_id, bill_type, bill_no, bill_date,
                        line_no, goods_id, qty, base_qty)
                    VALUES (?, ?, 'OTHER_IN', ?, DATE '2026-08-14', 1, ?, 2, 2)
                    """, stockItemId, stockDocumentId,
                    "SNAPSHOT-STOCK-" + stockDocumentId, goodsId);
            execute(connection, """
                    INSERT INTO subcontract_receipts (
                        id, bill_no, bill_date, warehouse_id, status)
                    VALUES (?, ?, DATE '2026-08-14', ?, 1)
                    """, subcontractReceiptId,
                    "SNAPSHOT-SUB-" + subcontractReceiptId, warehouseId);
            execute(connection, """
                    INSERT INTO subcontract_receipt_items (
                        id, bill_no, bill_date, receipt_id,
                        line_no, goods_id, qty)
                    VALUES (?, ?, DATE '2026-08-14', ?, 1, ?, 3)
                    """, subcontractReceiptItemId,
                    "SNAPSHOT-SUB-" + subcontractReceiptId,
                    subcontractReceiptId, goodsId);
            execute(connection, """
                    INSERT INTO employees (
                        id, code, full_name, id_type, department_id,
                        hire_date, status, employment_type)
                    SELECT ?, ?, 'Snapshot migration reviewer', id_type, department_id,
                           DATE '2026-08-14', 'active', 'regular'
                    FROM employees
                    WHERE code = 'ADMIN'
                    """, reviewerEmployeeId,
                    "SNAPSHOT-REVIEWER-" + reviewerEmployeeId);
            execute(connection, """
                    INSERT INTO users (
                        id, employee_id, login_account, password_hash, status)
                    VALUES (?, ?, ?, 'test-only-not-a-real-password', 'active')
                    """, reviewerUserId, reviewerEmployeeId,
                    "snapshot-reviewer-" + reviewerUserId);
            execute(connection, """
                    INSERT INTO procurement_arrival_exceptions (
                        id, order_type, receipt_id, receipt_item_id,
                        receipt_bill_no_snapshot, order_id, order_item_id,
                        order_bill_no_snapshot, goods_id, declared_qty,
                        approved_remaining_qty,
                        finance_assignee_user_id, finance_assignee_employee_id,
                        finance_assignee_name_snapshot, status,
                        detected_by_user_id, detected_by_employee_id)
                    VALUES (
                        ?, 'SUBCONTRACT', ?, ?, ?, ?, ?, ?, ?, 3, 0,
                        ?, ?, 'Snapshot migration reviewer',
                        'PENDING_FINANCE', ?, ?)
                    """, subcontractArrivalExceptionId,
                    subcontractReceiptId, subcontractReceiptItemId,
                    "SNAPSHOT-SUB-" + subcontractReceiptId,
                    UUID.randomUUID(), UUID.randomUUID(), "SNAPSHOT-SUB-ORDER",
                    goodsId, reviewerUserId, reviewerEmployeeId,
                    reviewerUserId, reviewerEmployeeId);
        }

        assertEquals(1, flyway("262").migrate().migrationsExecuted);
        assertSnapshot(
                "stock_document_items", stockItemId, "BACKFILL_V262", 2);

        assertEquals(1, flyway("263").migrate().migrationsExecuted);
        assertSnapshot(
                "subcontract_receipt_items", subcontractReceiptItemId,
                "BACKFILL_V263", 3);

        try (Connection connection = connection();
             PreparedStatement query = connection.prepareStatement("""
                     SELECT status
                     FROM procurement_arrival_exceptions
                     WHERE id = ?
                     """)) {
            query.setObject(1, subcontractArrivalExceptionId);
            try (ResultSet row = query.executeQuery()) {
                assertTrue(row.next());
                assertEquals("PENDING_FINANCE", row.getString(1));
            }
        }

        SQLException guarded = assertThrows(SQLException.class, () -> {
            try (Connection connection = connection();
                 PreparedStatement forbidden = connection.prepareStatement("""
                         UPDATE subcontract_receipt_items
                         SET remark = 'forbidden while finance review is open'
                         WHERE id = ?
                         """)) {
                forbidden.setObject(1, subcontractReceiptItemId);
                forbidden.executeUpdate();
            }
        });
        assertEquals("23514", guarded.getSQLState());
    }

    private static void assertSnapshot(
            String table, UUID id, String source, int quantity) throws Exception {
        try (Connection connection = connection();
             PreparedStatement query = connection.prepareStatement("""
                     SELECT goods_code_snapshot, goods_name_snapshot,
                            goods_snapshot_source, goods_snapshot_locked_at, qty
                     FROM %s
                     WHERE id = ?
                     """.formatted(table))) {
            query.setObject(1, id);
            try (ResultSet row = query.executeQuery()) {
                assertTrue(row.next());
                assertTrue(row.getString("goods_code_snapshot").startsWith("SNAPSHOT-"));
                assertEquals("deferred-trigger goods", row.getString("goods_name_snapshot"));
                assertEquals(source, row.getString("goods_snapshot_source"));
                assertNotNull(row.getObject("goods_snapshot_locked_at"));
                assertEquals(0, row.getBigDecimal("qty")
                        .compareTo(java.math.BigDecimal.valueOf(quantity)));
            }
        }
    }

    private static void execute(
            Connection connection, String sql, Object... values) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < values.length; index++) {
                statement.setObject(index + 1, values[index]);
            }
            assertEquals(1, statement.executeUpdate());
        }
    }

    private static Flyway flyway(String target) {
        return Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .callbacks(new AppliedMigrationCompatibilityCallback())
                .target(target)
                .load();
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
}
