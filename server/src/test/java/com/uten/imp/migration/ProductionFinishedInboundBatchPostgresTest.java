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
class ProductionFinishedInboundBatchPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static UUID actorUserId;
    private static UUID actorEmployeeId;

    @BeforeAll
    static void migrate() throws Exception {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
        try (Connection connection = connection()) {
            seedActors(connection);
        }
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void secondCommandFailureRollsBackFirstInsert() throws Exception {
        String key = "finished-in-batch-pg-01";
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            insertHeader(connection, UUID.randomUUID(), key, "0");
            SQLException conflict = assertThrows(
                    SQLException.class,
                    () -> insertHeader(
                            connection, UUID.randomUUID(), key, "1"));
            assertEquals("23505", conflict.getSQLState());
            connection.rollback();
        }

        try (Connection connection = connection();
             PreparedStatement count = connection.prepareStatement("""
                     SELECT COUNT(*)
                     FROM production_finished_in_confirm_batches
                     WHERE actor_user_id = ? AND idempotency_key = ?
                     """)) {
            count.setObject(1, actorUserId);
            count.setString(2, key);
            try (ResultSet rows = count.executeQuery()) {
                assertTrue(rows.next());
                assertEquals(0, rows.getInt(1));
            }
        }
    }

    private static void insertHeader(
            Connection connection, UUID id, String key, String hashDigit)
            throws SQLException {
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO production_finished_in_confirm_batches(
                    id, actor_user_id, actor_employee_id,
                    idempotency_key, request_hash, confirmed_count,
                    response_snapshot)
                VALUES (?, ?, ?, ?, repeat(?, 64), 1,
                        jsonb_build_object('confirmedCount', 1))
                """)) {
            insert.setObject(1, id);
            insert.setObject(2, actorUserId);
            insert.setObject(3, actorEmployeeId);
            insert.setString(4, key);
            insert.setString(5, hashDigit);
            assertEquals(1, insert.executeUpdate());
        }
    }

    private static void seedActors(Connection connection) throws SQLException {
        actorEmployeeId = UUID.randomUUID();
        actorUserId = UUID.randomUUID();
        connection.setAutoCommit(false);
        try (Statement statement = connection.createStatement()) {
            statement.execute("SET LOCAL session_replication_role = replica");
        }
        try (PreparedStatement employee = connection.prepareStatement("""
                INSERT INTO employees(
                    id, code, full_name, id_type, department_id,
                    hire_date, status, employment_type)
                VALUES (?, 'FIN-BATCH-PG', 'Finished batch probe', '其他', ?,
                        DATE '2026-08-30', 'active', 'regular')
                """);
             PreparedStatement user = connection.prepareStatement("""
                INSERT INTO users(
                    id, employee_id, login_account, password_hash, status)
                VALUES (?, ?, 'finished-batch-pg', 'test-only', 'active')
                """)) {
            employee.setObject(1, actorEmployeeId);
            employee.setObject(2, UUID.randomUUID());
            assertEquals(1, employee.executeUpdate());
            user.setObject(1, actorUserId);
            user.setObject(2, actorEmployeeId);
            assertEquals(1, user.executeUpdate());
        }
        connection.commit();
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }
}
