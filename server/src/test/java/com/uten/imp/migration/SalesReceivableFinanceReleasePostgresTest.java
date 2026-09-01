package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SalesReceivableFinanceReleasePostgresTest {

    private static final String CASH_CLIENT =
            "44300000-0000-4000-8100-000000000001";
    private static final String UNKNOWN_CLIENT =
            "44300000-0000-4000-8100-000000000002";
    private static final String MONTHLY_CLIENT =
            "44300000-0000-4000-8100-000000000004";
    private static final String HISTORICAL_SHIPMENT =
            "44300000-0000-4000-8200-000000000001";
    private static final String PENDING_SHIPMENT =
            "44300000-0000-4000-8200-000000000002";
    private static final String LEGACY_PENDING_SHIPMENT =
            "44300000-0000-4000-8200-000000000003";
    private static final String LEGACY_DRAFT_SHIPMENT =
            "44300000-0000-4000-8200-000000000004";
    private static final String AUDITOR_USER =
            "44300000-0000-4000-8300-000000000001";
    private static final String TEST_CURRENCY =
            "44300000-0000-4000-8400-000000000001";

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp_sales_receivable_v443")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    @BeforeAll
    static void migrateNonEmptyDatabase() throws Exception {
        POSTGRES.start();
        flyway("442").migrate();
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            statement.execute("SET app.business_identifier_legacy_import = 'on'");
            statement.executeUpdate("""
                    INSERT INTO users (
                        id, employee_id, login_account, password_hash, status)
                    SELECT '44300000-0000-4000-8300-000000000001'::uuid,
                           employee.id, 'ut-v443-auditor', 'test-only', 'active'
                    FROM employees employee
                    WHERE employee.code = 'ADMIN'
                    """);
            statement.executeUpdate("""
                    INSERT INTO currencies (
                        id, legacy_id, code, name, exchange_rate, status)
                    VALUES (
                        '44300000-0000-4000-8400-000000000001'::uuid,
                        443001, 'UT-CNY', 'V443 test CNY', 1, '使用')
                    """);
            statement.executeUpdate("""
                    INSERT INTO clients (
                        id, legacy_id, category_id, code, name, status,
                        code_sequence, credit, credit_floor,
                        default_settlement_method_id, price_style)
                    SELECT '44300000-0000-4000-8100-000000000001'::uuid,
                           443001, registry.client_category_id,
                           'UT-V443-CASH', 'V443 cash client', '使用',
                           443001, 50000, NULL,
                           '27300000-0000-4000-8100-000000000001'::uuid, 1
                    FROM system_master_category_registry registry
                    """);
            statement.executeUpdate("""
                    INSERT INTO clients (
                        id, legacy_id, category_id, code, name, status,
                        code_sequence, credit, credit_floor,
                        default_settlement_method_id, price_style)
                    SELECT '44300000-0000-4000-8100-000000000004'::uuid,
                           443004, registry.client_category_id,
                           'UT-V443-MONTHLY', 'V443 monthly client', '使用',
                           443004, 9000, NULL,
                           '27300000-0000-4000-8100-000000000006'::uuid, 6
                    FROM system_master_category_registry registry
                    """);
            statement.executeUpdate("""
                    INSERT INTO clients (
                        id, legacy_id, category_id, code, name, status,
                        code_sequence, credit, credit_floor,
                        default_settlement_method_id, price_style)
                    SELECT '44300000-0000-4000-8100-000000000002'::uuid,
                           443002, registry.client_category_id,
                           'UT-V443-UNKNOWN', 'V443 unknown client', '使用',
                           443002, NULL, NULL,
                           '27300000-0000-4000-8100-000000000008'::uuid, 8
                    FROM system_master_category_registry registry
                    """);
            statement.executeUpdate("""
                    INSERT INTO sales_shipments (
                        id, legacy_id, bill_no, bill_date, client_id,
                        status, warehouse_work_status, finance_audit)
                    VALUES (
                        '44300000-0000-4000-8200-000000000001'::uuid,
                        443001, 'XC-V443-HISTORICAL', DATE '2026-08-01',
                        '44300000-0000-4000-8100-000000000001'::uuid,
                        0, 'PICKING', 0)
                    """);
            statement.executeUpdate("""
                    INSERT INTO sales_shipments (
                        id, bill_no, bill_date, client_id,
                        status, warehouse_work_status, finance_audit)
                    VALUES (
                        '44300000-0000-4000-8200-000000000002'::uuid,
                        'XC-V443-PENDING', DATE '2026-08-01',
                        '44300000-0000-4000-8100-000000000001'::uuid,
                        0, 'PENDING_PICK', 0)
                    """);
            statement.executeUpdate("""
                    INSERT INTO sales_shipments (
                        id, legacy_id, bill_no, bill_date, client_id,
                        status, warehouse_work_status, finance_audit)
                    VALUES (
                        '44300000-0000-4000-8200-000000000004'::uuid,
                        443004, 'XC-V443-LEGACY-DRAFT', DATE '2026-08-01',
                        '44300000-0000-4000-8100-000000000001'::uuid,
                        0, 'LEGACY_PENDING', 0)
                    """);
            statement.executeUpdate("""
                    INSERT INTO sales_shipments (
                        id, legacy_id, bill_no, bill_date, client_id,
                        status, warehouse_work_status, finance_audit)
                    VALUES (
                        '44300000-0000-4000-8200-000000000003'::uuid,
                        443003, 'XC-V443-LEGACY-PENDING', DATE '2026-08-01',
                        '44300000-0000-4000-8100-000000000001'::uuid,
                        0, 'PENDING_PICK', 0)
                    """);
        }
        assertEquals(1, flyway("443").migrate().migrationsExecuted);
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void legacyFloorAndOnlyProvableLabelsAreBackfilled() throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            assertEquals("CASH", text(statement, """
                    SELECT sales_payment_type FROM clients
                    WHERE id = '44300000-0000-4000-8100-000000000001'
                    """));
            assertEquals("50000.0000", text(statement, """
                    SELECT credit_floor::text FROM clients
                    WHERE id = '44300000-0000-4000-8100-000000000001'
                    """));
            assertNull(text(statement, """
                    SELECT sales_payment_type FROM clients
                    WHERE id = '44300000-0000-4000-8100-000000000002'
                    """));
            assertEquals(1, scalar(statement, """
                    SELECT count(*) FROM v_client_sales_payment_type_migration_issues
                    WHERE client_id = '44300000-0000-4000-8100-000000000002'
                      AND issue_code = 'REQUIRES_MANUAL_CLASSIFICATION'
                    """));
            assertEquals("MONTHLY", text(statement, """
                    SELECT sales_payment_type FROM clients
                    WHERE id = '44300000-0000-4000-8100-000000000004'
                    """));
            assertEquals(1, scalar(statement, """
                    SELECT count(*) FROM settlement_methods
                    WHERE id = '27300000-0000-4000-8100-000000000006'::uuid
                      AND legacy_id = 6
                      AND system_role = 'MONTHLY'
                      AND status = '使用'
                      AND COALESCE(is_deleted, FALSE) = FALSE
                    """));
            assertEquals(1, scalar(statement, """
                    SELECT count(*) FROM settlement_methods
                    WHERE system_role = 'MONTHLY'
                    """));
        }
    }

    @Test
    void historicalPhysicalWorkIsNotFabricatedButNewPendingWorkIsGuarded()
            throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            assertEquals(0, scalar(statement, """
                    SELECT finance_gate_version FROM sales_shipments
                    WHERE id = '44300000-0000-4000-8200-000000000001'
                    """));
            assertEquals(0, scalar(statement, """
                    SELECT finance_audit FROM sales_shipments
                    WHERE id = '44300000-0000-4000-8200-000000000001'
                    """));
            assertEquals(1, scalar(statement, """
                    SELECT finance_gate_version FROM sales_shipments
                    WHERE id = '44300000-0000-4000-8200-000000000002'
                    """));
            assertEquals(1, scalar(statement, """
                    SELECT finance_gate_version FROM sales_shipments
                    WHERE id = '44300000-0000-4000-8200-000000000003'
                    """), "legacy-linked drafts with no physical work still require finance release");
            assertEquals(0, scalar(statement, """
                    SELECT finance_gate_version FROM sales_shipments
                    WHERE id = '44300000-0000-4000-8200-000000000004'
                    """), "legacy drafts keep unknown audit truth instead of fabricating release");
            assertEquals(1, scalar(statement, """
                    SELECT count(*)
                    FROM v_sales_shipment_finance_gate_migration_exceptions
                    WHERE shipment_id = '44300000-0000-4000-8200-000000000004'
                      AND warehouse_work_status = 'LEGACY_PENDING'
                    """), "legacy drafts must be visible in the manual rebuild exception queue");

            SQLException legacyWorkMutation = assertThrows(SQLException.class,
                    () -> statement.executeUpdate("""
                            UPDATE sales_shipments
                            SET warehouse_work_status = 'SHIPPED'
                            WHERE id = '44300000-0000-4000-8200-000000000004'
                            """));
            assertEquals("23514", legacyWorkMutation.getSQLState());
            assertTrue(legacyWorkMutation.getMessage().contains(
                    "legacy pending sales shipment is read-only"));

            SQLException legacyStatusMutation = assertThrows(SQLException.class,
                    () -> statement.executeUpdate("""
                            UPDATE sales_shipments
                            SET status = 1
                            WHERE id = '44300000-0000-4000-8200-000000000004'
                            """));
            assertEquals("23514", legacyStatusMutation.getSQLState());

            SQLException fabricatedLegacyApproval = assertThrows(SQLException.class,
                    () -> statement.executeUpdate("""
                            UPDATE sales_shipments
                            SET finance_gate_version = 1,
                                finance_audit = 1,
                                finance_auditor_id = gen_random_uuid(),
                                finance_audited_at = now()
                            WHERE id = '44300000-0000-4000-8200-000000000004'
                            """));
            assertEquals("23514", fabricatedLegacyApproval.getSQLState());
            assertEquals("LEGACY_PENDING", text(statement, """
                    SELECT warehouse_work_status FROM sales_shipments
                    WHERE id = '44300000-0000-4000-8200-000000000004'
                    """));

            SQLException missingApproval = assertThrows(SQLException.class,
                    () -> statement.executeUpdate("""
                            UPDATE sales_shipments
                            SET warehouse_work_status = 'PICKING'
                            WHERE id = '44300000-0000-4000-8200-000000000002'
                            """));
            assertEquals("23514", missingApproval.getSQLState());

            SQLException incompleteFacts = assertThrows(SQLException.class,
                    () -> statement.executeUpdate("""
                            UPDATE sales_shipments SET finance_audit = 1
                            WHERE id = '44300000-0000-4000-8200-000000000002'
                            """));
            assertEquals("23514", incompleteFacts.getSQLState());

            assertEquals(1, statement.executeUpdate("""
                    UPDATE sales_shipments
                    SET finance_audit = 1,
                        finance_auditor_id = gen_random_uuid(),
                        finance_audited_at = now()
                    WHERE id = '44300000-0000-4000-8200-000000000002'
                    """));
            assertEquals(1, statement.executeUpdate("""
                    UPDATE sales_shipments
                    SET warehouse_work_status = 'PICKING'
                    WHERE id = '44300000-0000-4000-8200-000000000002'
                    """));

            SQLException invalidApprovedTerminal = assertThrows(SQLException.class,
                    () -> statement.executeUpdate("""
                            UPDATE sales_shipments
                            SET status = 1
                            WHERE id = '44300000-0000-4000-8200-000000000002'
                            """));
            assertEquals("23514", invalidApprovedTerminal.getSQLState());
            assertTrue(invalidApprovedTerminal.getMessage().contains(
                    "sales_shipments_v1_shipped_terminal_chk"));
        }
    }

    @Test
    void newOnlineClientCannotRemainUnclassified() throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            statement.execute("SET app.business_identifier_legacy_import = 'on'");
            SQLException missingType = assertThrows(SQLException.class,
                    () -> statement.executeUpdate("""
                            INSERT INTO clients (
                                id, category_id, code, name, status,
                                code_sequence, credit_floor)
                            SELECT '44300000-0000-4000-8100-000000000003'::uuid,
                                   registry.client_category_id,
                                   'UT-V443-ONLINE-NULL', 'V443 online null type',
                                   '使用', 443003, 0
                            FROM system_master_category_registry registry
                            """));
            assertEquals("23514", missingType.getSQLState());
            assertTrue(missingType.getMessage().contains(
                    "clients_online_sales_payment_type_required_chk"));
            assertEquals(0, scalar(statement, """
                    SELECT count(*) FROM pg_constraint
                    WHERE conname='clients_online_sales_payment_type_required_chk'
                      AND convalidated
                    """), "the staged constraint must not fabricate classifications for old rows");
            assertEquals(2, scalar(statement, """
                    SELECT count(*)
                    FROM permission_surface_permissions link
                    JOIN permission_surfaces surface ON surface.id=link.surface_id
                    JOIN permissions permission ON permission.id=link.permission_id
                    WHERE (surface.id, surface.surface_key, permission.code) IN (
                        ('44300000-0000-4000-8000-000000000001'::uuid,
                         'finance.sales-shipment-audit', 'finance_shipment_audit'),
                        ('44300000-0000-4000-8000-000000000002'::uuid,
                         'warehouse.sales-outbound', 'sales_shipment:warehouse-work'))
                    """));
            assertEquals(0, scalar(statement, """
                    SELECT count(*)
                    FROM permission_surface_permissions link
                    JOIN permission_surfaces surface ON surface.id=link.surface_id
                    JOIN permissions permission ON permission.id=link.permission_id
                    WHERE surface.surface_key IN (
                        'finance.sales-shipment-audit', 'warehouse.sales-outbound')
                      AND (surface.surface_key, permission.code) NOT IN (
                        ('finance.sales-shipment-audit', 'finance_shipment_audit'),
                        ('warehouse.sales-outbound', 'sales_shipment:warehouse-work'))
                    """));
        }
    }

    @Test
    void financeReleaseDecisionEventsAreAuditedAndAlwaysAppendOnly()
            throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            assertEquals(0, scalar(statement, """
                    SELECT count(*) FROM sales_shipment_finance_release_events
                    """), "V443 must not fabricate historical decision snapshots");
            SQLException releasedWithoutClassification = assertThrows(
                    SQLException.class,
                    () -> statement.executeUpdate("""
                            INSERT INTO sales_shipment_finance_release_events (
                                shipment_id, event_type, actor_user_id, occurred_at,
                                client_id, client_name, currency_id,
                                sales_payment_type, shipment_total_original,
                                formal_ar_outstanding_local, credit_floor_local,
                                over_floor_local, available_prepayment_original,
                                available_prepayment_local)
                            VALUES (
                                '44300000-0000-4000-8200-000000000002'::uuid,
                                'RELEASED',
                                '44300000-0000-4000-8300-000000000001'::uuid,
                                now(),
                                '44300000-0000-4000-8100-000000000001'::uuid,
                                'V443 cash client',
                                '44300000-0000-4000-8400-000000000001'::uuid,
                                NULL, 25, 100, 50, 50, 20, 20)
                            """));
            assertEquals("23514", releasedWithoutClassification.getSQLState());
            String eventId = text(statement, """
                    INSERT INTO sales_shipment_finance_release_events (
                        shipment_id, event_type, actor_user_id, occurred_at,
                        client_id, client_name, currency_id, sales_payment_type,
                        settlement_method_id, shipment_total_original,
                        formal_ar_outstanding_local,
                        credit_floor_local, over_floor_local,
                        available_prepayment_original,
                        available_prepayment_local)
                    VALUES (
                        '44300000-0000-4000-8200-000000000002'::uuid,
                        'RELEASED',
                        '44300000-0000-4000-8300-000000000001'::uuid,
                        now(),
                        '44300000-0000-4000-8100-000000000001'::uuid,
                        'V443 cash client',
                        '44300000-0000-4000-8400-000000000001'::uuid,
                        'CASH',
                        '27300000-0000-4000-8100-000000000001'::uuid,
                        25, 100, 50, 50, 20, 20)
                    RETURNING id::text
                    """);
            assertTrue(eventId != null && !eventId.isBlank());
            assertEquals("A", text(statement, """
                    SELECT trigger.tgenabled::text
                    FROM pg_trigger trigger
                    WHERE trigger.tgrelid =
                          'sales_shipment_finance_release_events'::regclass
                      AND trigger.tgname =
                          'trg_guard_sales_shipment_finance_release_event_append_only'
                    """));

            SQLException update = assertThrows(SQLException.class,
                    () -> statement.executeUpdate(("""
                            UPDATE sales_shipment_finance_release_events
                            SET credit_floor_local = 60
                            WHERE id = '%s'::uuid
                            """).formatted(eventId)));
            assertEquals("23514", update.getSQLState());
            assertTrue(update.getMessage().contains("append-only"));

            SQLException delete = assertThrows(SQLException.class,
                    () -> statement.executeUpdate(("""
                            DELETE FROM sales_shipment_finance_release_events
                            WHERE id = '%s'::uuid
                            """).formatted(eventId)));
            assertEquals("23514", delete.getSQLState());
            assertEquals(1, scalar(statement, ("""
                    SELECT count(*) FROM sales_shipment_finance_release_events
                    WHERE id = '%s'::uuid
                    """).formatted(eventId)));
        }
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private static Flyway flyway(String target) {
        return Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target(target)
                .load();
    }

    private static long scalar(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getLong(1);
        }
    }

    private static String text(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getString(1);
        }
    }
}
