package com.uten.imp.migration;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Statement;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementInspectionOptionalPassReasonPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void startPostgresAndApplyV335() throws Exception {
        POSTGRES.start();
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            statement.execute("""
                    CREATE TABLE procurement_inspection_events (
                        action TEXT NOT NULL CHECK (action IN (
                            'RECEIVED', 'PASS', 'FAIL', 'PRODUCTION_WOKEN', 'RECEIPT_REVERSED')),
                        reason TEXT,
                        CONSTRAINT procurement_inspection_events_reason_chk CHECK (
                            action IN ('RECEIVED', 'PRODUCTION_WOKEN', 'RECEIPT_REVERSED')
                            OR NULLIF(btrim(reason), '') IS NOT NULL)
                    )
                    """);

            String sql = Files.readString(Path.of(
                    "src/main/resources/db/migration",
                    "V335__allow_optional_iqc_pass_reason.sql"), StandardCharsets.UTF_8)
                    .replaceAll("--[^\\r\\n]*", " ");
            for (String command : sql.split(";")) {
                if (!command.isBlank()) statement.execute(command);
            }
        }
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void migratedConstraintAllowsPassWithoutReasonAndRejectsFailWithoutReason()
            throws Exception {
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            assertEquals(1, statement.executeUpdate(
                    "INSERT INTO procurement_inspection_events(action, reason) VALUES ('PASS', NULL)"));
            assertEquals(1, statement.executeUpdate(
                    "INSERT INTO procurement_inspection_events(action, reason) VALUES ('PASS', '   ')"));

            for (String reason : new String[]{"NULL", "'   '"}) {
                SQLException error = assertThrows(SQLException.class, () -> statement.executeUpdate(
                        "INSERT INTO procurement_inspection_events(action, reason) VALUES ('FAIL', "
                                + reason + ")"));
                assertEquals("23514", error.getSQLState());
            }
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
}
