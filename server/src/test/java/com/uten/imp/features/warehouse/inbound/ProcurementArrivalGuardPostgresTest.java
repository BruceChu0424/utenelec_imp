package com.uten.imp.features.warehouse.inbound;

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
import java.sql.SQLException;
import java.time.LocalDate;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Real PostgreSQL proof for V201's receipt-bound finance allowance. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementArrivalGuardPostgresTest {

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
    void insertPathDoesNotReadOldAndUnapprovedOverageStillFails() throws Exception {
        UUID goodsId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        try (Connection connection = connection()) {
            insertGoodsAndOrder(connection, goodsId, orderId);
            assertEquals(1, insertOrderItem(
                    connection, UUID.randomUUID(), orderId, goodsId,
                    new BigDecimal("10.0000"), BigDecimal.ZERO));

            SQLException error = assertThrows(SQLException.class, () -> insertOrderItem(
                    connection, UUID.randomUUID(), orderId, goodsId,
                    new BigDecimal("10.0000"), new BigDecimal("10.0001")));
            assertEquals("23514", error.getSQLState());
            assertTrue(error.getMessage().contains(
                    "received_qty exceeds finance-approved arrival capacity"));
        }
    }

    @Test
    void approvedExcessCanOnlyBeConsumedByItsOwnReceipt() throws Exception {
        ArrivalFixture fixture;
        try (Connection connection = connection()) {
            fixture = insertArrivalFixture(connection);
        }

        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                setReceiptContext(connection, fixture.receiptId());
                assertEquals(1, updateReceivedQty(
                        connection, fixture.orderItemId(), new BigDecimal("15.0000")));
            } finally {
                connection.rollback();
            }
        }

        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                setReceiptContext(connection, UUID.randomUUID());
                SQLException error = assertThrows(SQLException.class, () -> updateReceivedQty(
                        connection, fixture.orderItemId(), new BigDecimal("15.0000")));
                assertEquals("23514", error.getSQLState());
                assertTrue(error.getMessage().contains(
                        "received_qty exceeds finance-approved arrival capacity"));
            } finally {
                connection.rollback();
            }
        }
    }

    private static ArrivalFixture insertArrivalFixture(Connection connection) throws Exception {
        UUID goodsId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        UUID receiptItemId = UUID.randomUUID();
        UUID exceptionId = UUID.randomUUID();
        Identity actor = loadIdentity(connection);

        insertGoodsAndOrder(connection, goodsId, orderId);
        insertOrderItem(
                connection, orderItemId, orderId, goodsId,
                new BigDecimal("10.0000"), BigDecimal.ZERO);

        try (PreparedStatement receipt = connection.prepareStatement("""
                insert into purchase_receipts(id, bill_no, bill_date, status)
                values (?, ?, ?, 0)
                """)) {
            receipt.setObject(1, receiptId);
            receipt.setString(2, "RC-ARR-" + receiptId);
            receipt.setObject(3, LocalDate.of(2026, 8, 2));
            assertEquals(1, receipt.executeUpdate());
        }
        try (PreparedStatement item = connection.prepareStatement("""
                insert into purchase_receipt_items(
                    id, bill_no, bill_date, receipt_id, order_item_id, goods_id, qty)
                values (?, ?, ?, ?, ?, ?, 15.0000)
                """)) {
            item.setObject(1, receiptItemId);
            item.setString(2, "RC-ARR-" + receiptId);
            item.setObject(3, LocalDate.of(2026, 8, 2));
            item.setObject(4, receiptId);
            item.setObject(5, orderItemId);
            item.setObject(6, goodsId);
            assertEquals(1, item.executeUpdate());
        }
        try (PreparedStatement exception = connection.prepareStatement("""
                insert into procurement_arrival_exceptions(
                    id, order_type, receipt_id, receipt_item_id,
                    receipt_bill_no_snapshot, order_id, order_item_id,
                    order_bill_no_snapshot, goods_id, declared_qty,
                    approved_remaining_qty, approved_excess_qty,
                    accepted_qty, unaccepted_qty,
                    finance_assignee_user_id, finance_assignee_employee_id,
                    finance_assignee_name_snapshot,
                    status, decision, finance_reason,
                    detected_by_user_id, detected_by_employee_id,
                    decided_by_user_id, decided_by_employee_id, decided_at)
                values (
                    ?, 'PURCHASE', ?, ?, ?, ?, ?, ?, ?, 15.0000,
                    10.0000, 5.0000, 15.0000, 0.0000,
                    ?, ?, ?, 'RECEIPT_ADJUSTED', 'APPROVE_ALL', ?,
                    ?, ?, ?, ?, now())
                """)) {
            int index = 1;
            exception.setObject(index++, exceptionId);
            exception.setObject(index++, receiptId);
            exception.setObject(index++, receiptItemId);
            exception.setString(index++, "RC-ARR-" + receiptId);
            exception.setObject(index++, orderId);
            exception.setObject(index++, orderItemId);
            exception.setString(index++, "PO-ARR-" + orderId);
            exception.setObject(index++, goodsId);
            exception.setObject(index++, actor.userId());
            exception.setObject(index++, actor.employeeId());
            exception.setString(index++, actor.name());
            exception.setString(index++, "finance approved full overage for database test");
            exception.setObject(index++, actor.userId());
            exception.setObject(index++, actor.employeeId());
            exception.setObject(index++, actor.userId());
            exception.setObject(index, actor.employeeId());
            assertEquals(1, exception.executeUpdate());
        }
        return new ArrivalFixture(orderItemId, receiptId);
    }

    private static void insertGoodsAndOrder(
            Connection connection, UUID goodsId, UUID orderId) throws Exception {
        try (PreparedStatement goods = connection.prepareStatement("""
                insert into goods(id, code, name, min_qty) values (?, ?, ?, 0)
                """)) {
            goods.setObject(1, goodsId);
            goods.setString(2, "G-ARR-" + goodsId);
            goods.setString(3, "Arrival guard test goods");
            assertEquals(1, goods.executeUpdate());
        }
        try (PreparedStatement order = connection.prepareStatement("""
                insert into purchase_orders(id, bill_no, bill_date, status)
                values (?, ?, ?, 1)
                """)) {
            order.setObject(1, orderId);
            order.setString(2, "PO-ARR-" + orderId);
            order.setObject(3, LocalDate.of(2026, 8, 2));
            assertEquals(1, order.executeUpdate());
        }
    }

    private static int insertOrderItem(
            Connection connection,
            UUID itemId,
            UUID orderId,
            UUID goodsId,
            BigDecimal qty,
            BigDecimal receivedQty) throws Exception {
        try (PreparedStatement item = connection.prepareStatement("""
                insert into purchase_order_items(
                    id, bill_no, bill_date, order_id, goods_id, qty, received_qty)
                values (?, ?, ?, ?, ?, ?, ?)
                """)) {
            item.setObject(1, itemId);
            item.setString(2, "POI-ARR-" + itemId);
            item.setObject(3, LocalDate.of(2026, 8, 2));
            item.setObject(4, orderId);
            item.setObject(5, goodsId);
            item.setBigDecimal(6, qty);
            item.setBigDecimal(7, receivedQty);
            return item.executeUpdate();
        }
    }

    private static Identity loadIdentity(Connection connection) throws Exception {
        UUID employeeId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        try (PreparedStatement employee = connection.prepareStatement("""
                insert into employees(
                    id, code, full_name, id_type, department_id, hire_date,
                    status, employment_type)
                select ?, ?, ?, '其他', department_id, ?, 'active', 'regular'
                from employees
                where code = 'ADMIN'
                """)) {
            employee.setObject(1, employeeId);
            employee.setString(2, "E-ARR-" + employeeId);
            employee.setString(3, "Arrival finance reviewer");
            employee.setObject(4, LocalDate.of(2026, 8, 2));
            assertEquals(1, employee.executeUpdate());
        }
        try (PreparedStatement user = connection.prepareStatement("""
                insert into users(id, employee_id, login_account, password_hash, status)
                values (?, ?, ?, 'test-only-not-a-real-password', 'active')
                """)) {
            user.setObject(1, userId);
            user.setObject(2, employeeId);
            user.setString(3, "arrival-finance-" + userId);
            assertEquals(1, user.executeUpdate());
        }
        return new Identity(userId, employeeId, "Arrival finance reviewer");
    }
    private static void setReceiptContext(Connection connection, UUID receiptId)
            throws Exception {
        try (PreparedStatement context = connection.prepareStatement("""
                select set_config('app.procurement_arrival_receipt_id', ?, true),
                       set_config('app.procurement_arrival_order_type', 'PURCHASE', true)
                """)) {
            context.setString(1, receiptId.toString());
            try (ResultSet result = context.executeQuery()) {
                assertTrue(result.next());
            }
        }
    }

    private static int updateReceivedQty(
            Connection connection, UUID orderItemId, BigDecimal qty) throws Exception {
        try (PreparedStatement update = connection.prepareStatement("""
                update purchase_order_items set received_qty = ? where id = ?
                """)) {
            update.setBigDecimal(1, qty);
            update.setObject(2, orderItemId);
            return update.executeUpdate();
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private record Identity(UUID userId, UUID employeeId, String name) {
    }

    private record ArrivalFixture(UUID orderItemId, UUID receiptId) {
    }
}
