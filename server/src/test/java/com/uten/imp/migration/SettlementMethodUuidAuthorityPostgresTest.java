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
import java.sql.Statement;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SettlementMethodUuidAuthorityPostgresTest {
    private static final UUID PLACEHOLDER_METHOD =
            UUID.fromString("27300000-0000-4000-8200-000000000001");
    private static final UUID SETTLEMENT_METHOD =
            UUID.fromString("27300000-0000-4000-8100-000000000007");
    private static final UUID CLIENT_ID =
            UUID.fromString("27300000-0000-4000-8300-000000000001");
    private static final UUID PURCHASE_RECEIPT_ID =
            UUID.fromString("27390000-0000-4000-8300-000000000001");
    private static final UUID SUBCONTRACT_RECEIPT_ID =
            UUID.fromString("27390000-0000-4000-8300-000000000002");
    private static final UUID GOODS_ID =
            UUID.fromString("27390000-0000-4000-8300-000000000003");
    private static final UUID REVIEWER_EMPLOYEE_ID =
            UUID.fromString("27390000-0000-4000-8300-000000000004");
    private static final UUID REVIEWER_USER_ID =
            UUID.fromString("27390000-0000-4000-8300-000000000005");

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void migrate() throws Exception {
        POSTGRES.start();
        flyway("272").migrate();
        seedGuardedLegacyReceiptHeaders();
        assertEquals(1, flyway("273").migrate().migrationsExecuted);
    }

    @Test
    void nonEmptyUpgradeMapsGuardedReceiptHeadersAndLeavesArrivalControlEnabled()
            throws Exception {
        try (Connection connection = connection()) {
            assertEquals(
                    "27300000-0000-4000-8100-000000000001",
                    textScalar(connection, """
                            SELECT settlement_method_id::text
                            FROM purchase_receipts
                            WHERE id = '27390000-0000-4000-8300-000000000001'
                            """));
            assertEquals(
                    "27300000-0000-4000-8100-000000000007",
                    textScalar(connection, """
                            SELECT settlement_method_id::text
                            FROM subcontract_receipts
                            WHERE id = '27390000-0000-4000-8300-000000000002'
                            """));
            assertEquals(2, scalar(connection, """
                    SELECT COUNT(*)
                    FROM procurement_arrival_exceptions
                    WHERE receipt_id IN (
                        '27390000-0000-4000-8300-000000000001',
                        '27390000-0000-4000-8300-000000000002')
                      AND status = 'PENDING_FINANCE'
                    """));
        }

        assertHeaderArrivalGuard("purchase_receipts", PURCHASE_RECEIPT_ID);
        assertHeaderArrivalGuard("subcontract_receipts", SUBCONTRACT_RECEIPT_ID);
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void normalWritesRequireConfirmedFinanceUuidAndCanonicalizeBothShadows()
            throws Exception {
        try (Connection connection = connection()) {
            SQLException placeholderError = assertThrows(SQLException.class,
                    () -> insertExpense(connection, "UT-V273-PH", PLACEHOLDER_METHOD, null));
            assertEquals("23514", placeholderError.getSQLState());

            connection.setAutoCommit(false);
            try (Statement mode = connection.createStatement()) {
                mode.execute("SELECT set_config('uten.legacy_reference_import','pg-v273',true)");
            }
            insertExpense(connection, "UT-V273-IMPORT", PLACEHOLDER_METHOD, null);
            connection.commit();
            connection.setAutoCommit(true);
            assertEquals(1, scalar(connection, """
                    SELECT payment_method_legacy_id
                    FROM finance_expenses WHERE bill_no='UT-V273-IMPORT'
                    """));

            try (Statement confirm = connection.createStatement()) {
                assertEquals(1, confirm.executeUpdate("""
                        UPDATE finance_payment_methods
                        SET name='已核对方式', legacy_name_confirmed=true
                        WHERE id='27300000-0000-4000-8200-000000000001'
                        """));
            }
            insertExpense(connection, "UT-V273-NORMAL", PLACEHOLDER_METHOD, null);
            assertEquals(1, scalar(connection, """
                    SELECT payment_method_legacy_id
                    FROM finance_expenses WHERE bill_no='UT-V273-NORMAL'
                    """));

            SQLException conflict = assertThrows(SQLException.class,
                    () -> insertExpense(connection, "UT-V273-CONFLICT", PLACEHOLDER_METHOD, 2));
            assertEquals("23514", conflict.getSQLState());
            SQLException legacyOnly = assertThrows(SQLException.class,
                    () -> insertExpense(connection, "UT-V273-LEGACY", null, 1));
            assertEquals("23514", legacyOnly.getSQLState());

            try (PreparedStatement client = connection.prepareStatement("""
                    INSERT INTO clients (id, code, name, status, code_sequence)
                    VALUES (?, 'UT-V273-CLIENT', '结算方式测试客户', '使用', 1)
                    """)) {
                client.setObject(1, CLIENT_ID);
                assertEquals(1, client.executeUpdate());
            }
            insertLedger(connection, "UT-V273-AR", SETTLEMENT_METHOD, null);
            assertEquals(7, scalar(connection, """
                    SELECT settlement_style_legacy
                    FROM ar_ap_ledger WHERE bill_no='UT-V273-AR'
                    """));
            SQLException settlementConflict = assertThrows(SQLException.class,
                    () -> insertLedger(connection, "UT-V273-AR-CONFLICT", SETTLEMENT_METHOD, 6));
            assertEquals("23514", settlementConflict.getSQLState());
            SQLException settlementLegacyOnly = assertThrows(SQLException.class,
                    () -> insertLedger(connection, "UT-V273-AR-LEGACY", null, 7));
            assertEquals("23514", settlementLegacyOnly.getSQLState());

            assertTrue(scalar(connection, """
                    SELECT COUNT(*) FROM pg_trigger
                    WHERE tgname IN ('trg_finance_method_ref_expenses',
                                     'trg_settlement_ref_ar_ap_ledger')
                      AND NOT tgisinternal
                    """) == 2);
        }
    }

    private static void insertExpense(
            Connection connection, String billNo, UUID methodId, Integer legacyId) throws SQLException {
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO finance_expenses
                    (bill_no, bill_date, payment_method_id, payment_method_legacy_id)
                VALUES (?, DATE '2026-08-14', ?, ?)
                """)) {
            insert.setString(1, billNo);
            insert.setObject(2, methodId);
            if (legacyId == null) insert.setNull(3, java.sql.Types.INTEGER);
            else insert.setInt(3, legacyId);
            assertEquals(1, insert.executeUpdate());
        }
    }

    private static void insertLedger(
            Connection connection, String billNo, UUID methodId, Integer legacyId) throws SQLException {
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO ar_ap_ledger
                    (direction, source_doc_type, bill_date, client_id,
                     amount_original_local, amount_balance, bill_no,
                     settlement_type_id, settlement_style_legacy)
                VALUES ('AR', 'DIRECT_RECEIPT', DATE '2026-08-14', ?, 1, 1, ?, ?, ?)
                """)) {
            insert.setObject(1, CLIENT_ID);
            insert.setString(2, billNo);
            insert.setObject(3, methodId);
            if (legacyId == null) insert.setNull(4, java.sql.Types.SMALLINT);
            else insert.setInt(4, legacyId);
            assertEquals(1, insert.executeUpdate());
        }
    }

    private static int scalar(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getInt(1);
        }
    }

    private static String textScalar(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getString(1);
        }
    }

    private static void seedGuardedLegacyReceiptHeaders() throws Exception {
        try (Connection connection = connection()) {
            execute(connection, """
                    INSERT INTO goods (id, code, name, code_sequence)
                    VALUES (?, 'V273-GOODS', 'V273 settlement upgrade goods',
                            (SELECT COALESCE(max(code_sequence), 0) + 1 FROM goods))
                    """, GOODS_ID);
            execute(connection, """
                    INSERT INTO employees (
                        id, code, full_name, id_type, department_id,
                        hire_date, status, employment_type)
                    SELECT ?, 'V273-REVIEWER', 'V273 migration reviewer',
                           id_type, department_id, DATE '2026-08-14',
                           'active', 'regular'
                    FROM employees
                    WHERE code = 'ADMIN'
                    """, REVIEWER_EMPLOYEE_ID);
            execute(connection, """
                    INSERT INTO users (
                        id, employee_id, login_account, password_hash, status)
                    VALUES (?, ?, 'v273-migration-reviewer',
                            'test-only-not-a-real-password', 'active')
                    """, REVIEWER_USER_ID, REVIEWER_EMPLOYEE_ID);
            execute(connection, """
                    INSERT INTO purchase_receipts (
                        id, bill_no, bill_date, settlement_style_legacy)
                    VALUES (?, 'V273-PURCHASE', DATE '2026-08-14', 1)
                    """, PURCHASE_RECEIPT_ID);
            execute(connection, """
                    INSERT INTO subcontract_receipts (
                        id, bill_no, bill_date, settlement_style_legacy)
                    VALUES (?, 'V273-SUBCONTRACT', DATE '2026-08-14', 7)
                    """, SUBCONTRACT_RECEIPT_ID);
            insertArrivalException(connection, "PURCHASE", PURCHASE_RECEIPT_ID);
            insertArrivalException(connection, "SUBCONTRACT", SUBCONTRACT_RECEIPT_ID);
        }
    }

    private static void insertArrivalException(
            Connection connection, String orderType, UUID receiptId) throws Exception {
        execute(connection, """
                INSERT INTO procurement_arrival_exceptions (
                    id, order_type, receipt_id, receipt_item_id,
                    receipt_bill_no_snapshot, order_id, order_item_id,
                    order_bill_no_snapshot, goods_id, declared_qty,
                    approved_remaining_qty,
                    finance_assignee_user_id, finance_assignee_employee_id,
                    finance_assignee_name_snapshot, status,
                    detected_by_user_id, detected_by_employee_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?,
                        'V273 migration reviewer', 'PENDING_FINANCE', ?, ?)
                """, UUID.randomUUID(), orderType, receiptId, UUID.randomUUID(),
                "V273-" + orderType + "-RECEIPT", UUID.randomUUID(), UUID.randomUUID(),
                "V273-" + orderType + "-ORDER", GOODS_ID,
                REVIEWER_USER_ID, REVIEWER_EMPLOYEE_ID,
                REVIEWER_USER_ID, REVIEWER_EMPLOYEE_ID);
    }

    private static void assertHeaderArrivalGuard(String table, UUID receiptId) {
        SQLException guarded = assertThrows(SQLException.class, () -> {
            try (Connection connection = connection();
                 PreparedStatement forbidden = connection.prepareStatement("""
                         UPDATE %s
                         SET remark = 'forbidden while finance review is open'
                         WHERE id = ?
                         """.formatted(table))) {
                forbidden.setObject(1, receiptId);
                forbidden.executeUpdate();
            }
        });
        assertEquals("23514", guarded.getSQLState());
    }

    private static void execute(
            Connection connection, String sql, Object... values) throws SQLException {
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

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
}
