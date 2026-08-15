package com.uten.imp.features.purchase;

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
import java.sql.Statement;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Non-empty V259 -> V260 rehearsal with the deferred purchase triggers installed. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PurchaseGoodsHistorySnapshotPostgresTest {

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
    void v260BackfillsRowsBeforeTighteningSnapshotProvenance() throws Exception {
        flyway("259").migrate();

        UUID goodsId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        UUID receiptItemId = UUID.randomUUID();
        UUID arrivalExceptionId = UUID.randomUUID();
        UUID reviewerEmployeeId = UUID.randomUUID();
        UUID reviewerUserId = UUID.randomUUID();
        try (Connection connection = connection()) {
            try (PreparedStatement goods = connection.prepareStatement("""
                    INSERT INTO goods (id, code, name, code_sequence)
                    VALUES (?, ?, 'V260 historical goods',
                            (SELECT COALESCE(max(code_sequence), 0) + 1 FROM goods))
                    """)) {
                goods.setObject(1, goodsId);
                goods.setString(2, "V260-" + goodsId);
                assertEquals(1, goods.executeUpdate());
            }
            try (PreparedStatement order = connection.prepareStatement("""
                    INSERT INTO purchase_orders (id, bill_no, bill_date, status)
                    VALUES (?, ?, DATE '2026-08-14', 1)
                    """)) {
                order.setObject(1, orderId);
                order.setString(2, "V260-ORDER-" + orderId);
                assertEquals(1, order.executeUpdate());
            }
            try (PreparedStatement item = connection.prepareStatement("""
                    INSERT INTO purchase_order_items (
                        id, bill_no, bill_date, order_id, goods_id, qty)
                    VALUES (?, ?, DATE '2026-08-14', ?, ?, 1)
                    """)) {
                item.setObject(1, orderItemId);
                item.setString(2, "V260-ORDER-" + orderId);
                item.setObject(3, orderId);
                item.setObject(4, goodsId);
                assertEquals(1, item.executeUpdate());
            }
            try (PreparedStatement receipt = connection.prepareStatement("""
                    INSERT INTO purchase_receipts (id, bill_no, bill_date, status)
                    VALUES (?, ?, DATE '2026-08-14', 0)
                    """)) {
                receipt.setObject(1, receiptId);
                receipt.setString(2, "V260-RECEIPT-" + receiptId);
                assertEquals(1, receipt.executeUpdate());
            }
            try (PreparedStatement item = connection.prepareStatement("""
                    INSERT INTO purchase_receipt_items (
                        id, bill_no, bill_date, receipt_id,
                        order_item_id, goods_id, qty)
                    VALUES (?, ?, DATE '2026-08-14', ?, ?, ?, 1)
                    """)) {
                item.setObject(1, receiptItemId);
                item.setString(2, "V260-RECEIPT-" + receiptId);
                item.setObject(3, receiptId);
                item.setObject(4, orderItemId);
                item.setObject(5, goodsId);
                assertEquals(1, item.executeUpdate());
            }
            try (PreparedStatement employee = connection.prepareStatement("""
                    INSERT INTO employees (
                        id, code, full_name, id_type, department_id,
                        hire_date, status, employment_type)
                    SELECT ?, ?, 'V260 migration reviewer', id_type, department_id,
                           DATE '2026-08-14', 'active', 'regular'
                    FROM employees
                    WHERE code = 'ADMIN'
                    """)) {
                employee.setObject(1, reviewerEmployeeId);
                employee.setString(2, "V260-REVIEWER-" + reviewerEmployeeId);
                assertEquals(1, employee.executeUpdate());
            }
            try (PreparedStatement user = connection.prepareStatement("""
                    INSERT INTO users (
                        id, employee_id, login_account, password_hash, status)
                    VALUES (?, ?, ?, 'test-only-not-a-real-password', 'active')
                    """)) {
                user.setObject(1, reviewerUserId);
                user.setObject(2, reviewerEmployeeId);
                user.setString(3, "v260-reviewer-" + reviewerUserId);
                assertEquals(1, user.executeUpdate());
            }
            try (PreparedStatement exception = connection.prepareStatement("""
                    INSERT INTO procurement_arrival_exceptions (
                        id, order_type, receipt_id, receipt_item_id,
                        receipt_bill_no_snapshot, order_id, order_item_id,
                        order_bill_no_snapshot, goods_id, declared_qty,
                        approved_remaining_qty,
                        finance_assignee_user_id, finance_assignee_employee_id,
                        finance_assignee_name_snapshot, status,
                        detected_by_user_id, detected_by_employee_id)
                    VALUES (
                        ?, 'PURCHASE', ?, ?, ?, ?, ?, ?, ?, 1, 0,
                        ?, ?, 'V260 migration reviewer', 'PENDING_FINANCE', ?, ?)
                    """)) {
                int parameter = 1;
                exception.setObject(parameter++, arrivalExceptionId);
                exception.setObject(parameter++, receiptId);
                exception.setObject(parameter++, receiptItemId);
                exception.setString(parameter++, "V260-RECEIPT-" + receiptId);
                exception.setObject(parameter++, orderId);
                exception.setObject(parameter++, orderItemId);
                exception.setString(parameter++, "V260-ORDER-" + orderId);
                exception.setObject(parameter++, goodsId);
                exception.setObject(parameter++, reviewerUserId);
                exception.setObject(parameter++, reviewerEmployeeId);
                exception.setObject(parameter++, reviewerUserId);
                exception.setObject(parameter, reviewerEmployeeId);
                assertEquals(1, exception.executeUpdate());
            }
        }

        assertEquals(1, flyway("260").migrate().migrationsExecuted);

        assertSnapshot("purchase_order_items", orderItemId, goodsId, true);
        assertSnapshot("purchase_receipt_items", receiptItemId, goodsId, false);

        try (Connection connection = connection();
             Statement query = connection.createStatement();
             ResultSet column = query.executeQuery("""
                     SELECT is_nullable, column_default
                     FROM information_schema.columns
                     WHERE table_schema = 'public'
                       AND table_name = 'purchase_order_items'
                       AND column_name = 'goods_snapshot_source'
                     """)) {
            assertTrue(column.next());
            assertEquals("NO", column.getString("is_nullable"));
            assertNull(column.getString("column_default"));
        }

        try (Connection connection = connection();
             PreparedStatement status = connection.prepareStatement("""
                     SELECT status
                     FROM procurement_arrival_exceptions
                     WHERE id = ?
                     """)) {
            status.setObject(1, arrivalExceptionId);
            try (ResultSet row = status.executeQuery()) {
                assertTrue(row.next());
                assertEquals("PENDING_FINANCE", row.getString(1));
            }
        }

        SQLException guarded = assertThrows(SQLException.class, () -> {
            try (Connection connection = connection();
                 PreparedStatement forbidden = connection.prepareStatement("""
                         UPDATE purchase_receipt_items
                         SET remark = 'forbidden while finance review is open'
                         WHERE id = ?
                         """)) {
                forbidden.setObject(1, receiptItemId);
                forbidden.executeUpdate();
            }
        });
        assertEquals("23514", guarded.getSQLState());
    }

    private static void assertSnapshot(
            String table, UUID itemId, UUID goodsId, boolean locked) throws Exception {
        try (Connection connection = connection();
             PreparedStatement snapshot = connection.prepareStatement("""
                     SELECT goods_code_snapshot, goods_name_snapshot,
                            goods_snapshot_source, goods_snapshot_locked_at
                     FROM %s
                     WHERE id = ?
                     """.formatted(table))) {
            snapshot.setObject(1, itemId);
            try (ResultSet row = snapshot.executeQuery()) {
                assertTrue(row.next());
                assertEquals("V260-" + goodsId, row.getString("goods_code_snapshot"));
                assertEquals("V260 historical goods", row.getString("goods_name_snapshot"));
                assertEquals("BACKFILL_V260", row.getString("goods_snapshot_source"));
                if (locked) {
                    assertNotNull(row.getObject("goods_snapshot_locked_at"));
                } else {
                    assertNull(row.getObject("goods_snapshot_locked_at"));
                }
            }
        }
    }

    private static Flyway flyway(String target) {
        return Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .callbacks(new com.uten.imp.migration.AppliedMigrationCompatibilityCallback())
                .target(target)
                .load();
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
}
