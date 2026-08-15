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

/** Non-empty V268 -> V269 rehearsal for purchase report UUID relationships. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PurchaseReportUuidReferencePostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static UUID departmentId;
    private static UUID employeeId;
    private static UUID requestId;
    private static UUID receiptId;

    @BeforeAll
    static void migrateToV268AndSeedHistoricalRows() throws Exception {
        POSTGRES.start();
        flyway("268").migrate();

        departmentId = UUID.randomUUID();
        employeeId = UUID.randomUUID();
        requestId = UUID.randomUUID();
        receiptId = UUID.randomUUID();
        try (Connection connection = connection()) {
            try (PreparedStatement department = connection.prepareStatement("""
                    INSERT INTO departments (
                        id, code, name, level, path, sort_order, headcount,
                        is_deleted)
                    VALUES (?, ?, '采购 UUID 迁移部门', '一级部门', ?, 0, 0, false)
                    """)) {
                department.setObject(1, departmentId);
                department.setString(2, "DEPT-V269-" + departmentId.toString().substring(0, 8));
                department.setString(3, "/V269-" + departmentId + "/");
                assertEquals(1, department.executeUpdate());
            }
            try (PreparedStatement employee = connection.prepareStatement("""
                    INSERT INTO employees (
                        id, legacy_id, code, full_name, id_type, department_id,
                        hire_date, status, employment_type, is_deleted)
                    VALUES (?, 969002, ?, '采购 UUID 迁移员工', '其他', ?,
                            DATE '2026-01-01', 'active', 'regular', false)
                    """)) {
                employee.setObject(1, employeeId);
                employee.setString(2, "EMP-V269-" + employeeId.toString().substring(0, 8));
                employee.setObject(3, departmentId);
                assertEquals(1, employee.executeUpdate());
            }
            try (PreparedStatement legacyDepartment = connection.prepareStatement("""
                    INSERT INTO legacy_departments (legacy_id, name, code, department_id)
                    VALUES (969001, '采购 UUID 迁移部门', 'V269', ?)
                    """)) {
                legacyDepartment.setObject(1, departmentId);
                assertEquals(1, legacyDepartment.executeUpdate());
            }
            try (PreparedStatement request = connection.prepareStatement("""
                    INSERT INTO purchase_requests (
                        id, bill_no, bill_date, status, department_legacy_id)
                    VALUES (?, 'CS-V269', DATE '2026-08-14', 0, 969001)
                    """)) {
                request.setObject(1, requestId);
                assertEquals(1, request.executeUpdate());
            }
            try (PreparedStatement receipt = connection.prepareStatement("""
                    INSERT INTO purchase_receipts (
                        id, bill_no, bill_date, status, purchaser_legacy_id)
                    VALUES (?, 'CJ-V269', DATE '2026-08-14', 0, 969002)
                    """)) {
                receipt.setObject(1, receiptId);
                assertEquals(1, receipt.executeUpdate());
            }
            try (Statement sentinel = connection.createStatement()) {
                assertEquals(1, sentinel.executeUpdate("""
                        INSERT INTO purchase_requests (
                            id, bill_no, bill_date, status, department_legacy_id)
                        VALUES (gen_random_uuid(), 'CS-V269-ZERO',
                                DATE '2026-08-14', 0, 0)
                        """));
                assertEquals(1, sentinel.executeUpdate("""
                        INSERT INTO purchase_receipts (
                            id, bill_no, bill_date, status, purchaser_legacy_id)
                        VALUES (gen_random_uuid(), 'CJ-V269-ZERO',
                                DATE '2026-08-14', 0, 0)
                        """));
            }
        }
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void v269BackfillsUuidTruthValidatesFksAndKeepsLegacySnapshots()
            throws Exception {
        assertEquals(1, flyway("269").migrate().migrationsExecuted);

        try (Connection connection = connection()) {
            assertEquals(departmentId, uuid(connection,
                    "SELECT department_id FROM purchase_requests WHERE id=?", requestId));
            assertEquals(employeeId, uuid(connection,
                    "SELECT purchaser_id FROM purchase_receipts WHERE id=?", receiptId));
            assertEquals(969001, integer(connection,
                    "SELECT department_legacy_id FROM purchase_requests WHERE id=?", requestId));
            assertEquals(969002, integer(connection,
                    "SELECT purchaser_legacy_id FROM purchase_receipts WHERE id=?", receiptId));
            assertEquals(2, scalar(connection, """
                    SELECT count(*) FROM pg_constraint
                    WHERE conname IN ('fk_purchase_receipts_purchaser',
                                      'fk_purchase_requests_department')
                      AND convalidated
                    """));
            assertEquals(1, scalar(connection, """
                    SELECT count(*) FROM purchase_requests
                    WHERE department_legacy_id=0 AND department_id IS NULL
                    """));
            assertEquals(1, scalar(connection, """
                    SELECT count(*) FROM purchase_receipts
                    WHERE purchaser_legacy_id=0 AND purchaser_id IS NULL
                    """));
        }

        SQLException invalidReference = assertThrows(SQLException.class, () -> {
            try (Connection connection = connection();
                 PreparedStatement update = connection.prepareStatement("""
                         UPDATE purchase_receipts SET purchaser_id=? WHERE id=?
                         """)) {
                update.setObject(1, UUID.randomUUID());
                update.setObject(2, receiptId);
                update.executeUpdate();
            }
        });
        assertEquals("23503", invalidReference.getSQLState());
    }

    private static UUID uuid(Connection connection, String sql, UUID id) throws Exception {
        try (PreparedStatement query = connection.prepareStatement(sql)) {
            query.setObject(1, id);
            try (ResultSet result = query.executeQuery()) {
                assertTrue(result.next());
                return result.getObject(1, UUID.class);
            }
        }
    }

    private static int integer(Connection connection, String sql, UUID id) throws Exception {
        try (PreparedStatement query = connection.prepareStatement(sql)) {
            query.setObject(1, id);
            try (ResultSet result = query.executeQuery()) {
                assertTrue(result.next());
                return result.getInt(1);
            }
        }
    }

    private static int scalar(Connection connection, String sql) throws Exception {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getInt(1);
        }
    }

    private static Flyway flyway(String target) {
        return Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target(target)
                .load();
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
}
