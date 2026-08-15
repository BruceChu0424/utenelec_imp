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
class ClientDefaultSettlementMethodUuidPostgresTest {
    private static final UUID MATCHED_CLIENT =
            UUID.fromString("28500000-0000-4000-8100-000000000001");
    private static final UUID UNMATCHED_CLIENT =
            UUID.fromString("28500000-0000-4000-8100-000000000002");
    private static final UUID METHOD_6 =
            UUID.fromString("27300000-0000-4000-8100-000000000006");
    private static final UUID METHOD_7 =
            UUID.fromString("27300000-0000-4000-8100-000000000007");
    private static String migratedMatchedMethodId;

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void migrate() throws Exception {
        POSTGRES.start();
        flyway("284").migrate();
        try (Connection connection = connection()) {
            insertClient(connection, MATCHED_CLIENT, "UT-V285-MATCH", 6, 285001);
            insertClient(connection, UNMATCHED_CLIENT, "UT-V285-MISSING", 99, 285002);
        }
        assertEquals(1, flyway("285").migrate().migrationsExecuted);
        try (Connection connection = connection()) {
            migratedMatchedMethodId = textScalar(connection, """
                    SELECT default_settlement_method_id::text
                    FROM clients WHERE id = '28500000-0000-4000-8100-000000000001'
                    """);
        }
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void migrationBackfillsOnlyProvableUuidAndRecordsMissingLegacyDefault()
            throws Exception {
        try (Connection connection = connection()) {
            assertEquals(METHOD_6.toString(), migratedMatchedMethodId);
            assertEquals(1, intScalar(connection, """
                    SELECT count(*)
                    FROM client_default_settlement_migration_issues
                    WHERE client_id = '28500000-0000-4000-8100-000000000002'
                      AND issue_code = 'MISSING_ACTIVE_METHOD'
                      AND active_match_count = 0
                    """));
            assertEquals("CASH", textScalar(connection, """
                    SELECT system_role FROM settlement_methods
                    WHERE id = '27300000-0000-4000-8100-000000000001'
                    """));
            assertEquals(1, intScalar(connection, """
                    SELECT count(*) FROM pg_trigger
                    WHERE tgname = 'trg_audit_client_default_settlement_migration_issues'
                      AND NOT tgisinternal
                    """));
        }
    }

    @Test
    void onlineUuidWritesCanonicalizeShadowAndLegacyOnlyWritesFailClosed()
            throws Exception {
        try (Connection connection = connection()) {
            try (PreparedStatement update = connection.prepareStatement("""
                    UPDATE clients
                    SET default_settlement_method_id = ?, price_style = NULL
                    WHERE id = ?
                    """)) {
                update.setObject(1, METHOD_7);
                update.setObject(2, MATCHED_CLIENT);
                assertEquals(1, update.executeUpdate());
            }
            assertEquals(7, intScalar(connection, """
                    SELECT price_style FROM clients
                    WHERE id = '28500000-0000-4000-8100-000000000001'
                    """));

            SQLException conflict = assertThrows(SQLException.class, () -> {
                try (PreparedStatement update = connection.prepareStatement("""
                        UPDATE clients
                        SET default_settlement_method_id = ?, price_style = 7
                        WHERE id = ?
                        """)) {
                    update.setObject(1, METHOD_6);
                    update.setObject(2, MATCHED_CLIENT);
                    update.executeUpdate();
                }
            });
            assertEquals("23514", conflict.getSQLState());

            try (Statement mode = connection.createStatement()) {
                mode.execute("SET uten.legacy_reference_import = 'arbitrary-nonempty'");
            }
            SQLException legacyOnly = assertThrows(SQLException.class,
                    () -> insertClient(
                            connection, UUID.randomUUID(), "UT-V285-LEGACY", 6, 285003));
            assertEquals("23514", legacyOnly.getSQLState());
            try (Statement mode = connection.createStatement()) {
                mode.execute("RESET uten.legacy_reference_import");
            }
        }
    }

    @Test
    void activeClientAndSystemRoleProtectSettlementMasterMeaning() throws Exception {
        try (Connection connection = connection()) {
            try (PreparedStatement update = connection.prepareStatement("""
                    UPDATE clients
                    SET default_settlement_method_id = ?, price_style = NULL
                    WHERE id = ?
                    """)) {
                update.setObject(1, METHOD_7);
                update.setObject(2, MATCHED_CLIENT);
                assertEquals(1, update.executeUpdate());
            }
            SQLException disable = assertThrows(SQLException.class, () -> {
                try (PreparedStatement update = connection.prepareStatement("""
                        UPDATE settlement_methods SET status = '禁用' WHERE id = ?
                        """)) {
                    update.setObject(1, METHOD_7);
                    update.executeUpdate();
                }
            });
            assertEquals("23514", disable.getSQLState());

            SQLException roleCreation = assertThrows(SQLException.class, () -> {
                try (PreparedStatement update = connection.prepareStatement("""
                        UPDATE settlement_methods SET system_role = 'UNCONTROLLED' WHERE id = ?
                        """)) {
                    update.setObject(1, METHOD_6);
                    update.executeUpdate();
                }
            });
            assertEquals("23514", roleCreation.getSQLState());

            SQLException cashCodeChange = assertThrows(SQLException.class, () -> {
                try (Statement update = connection.createStatement()) {
                    update.executeUpdate("""
                            UPDATE settlement_methods SET code = 'UNSAFE-CASH-RENAME'
                            WHERE system_role = 'CASH'
                            """);
                }
            });
            assertEquals("23514", cashCodeChange.getSQLState());
        }
    }

    private static void insertClient(
            Connection connection, UUID id, String code, int priceStyle, long sequence)
            throws SQLException {
        try (PreparedStatement insert = connection.prepareStatement("""
                INSERT INTO clients (
                    id, category_id, code, name, status, code_sequence, price_style)
                SELECT ?, registry.client_category_id, ?, ?, '使用', ?, ?
                FROM system_master_category_registry registry
                """)) {
            insert.setObject(1, id);
            insert.setString(2, code);
            insert.setString(3, code + " client");
            insert.setLong(4, sequence);
            insert.setInt(5, priceStyle);
            assertEquals(1, insert.executeUpdate());
        }
    }

    private static int intScalar(Connection connection, String sql) throws SQLException {
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
}
