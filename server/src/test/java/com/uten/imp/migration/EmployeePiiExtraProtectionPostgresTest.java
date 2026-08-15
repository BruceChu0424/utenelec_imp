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
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Non-empty V281 -> V282 rehearsal for the legacy employee PII write guard. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class EmployeePiiExtraProtectionPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static UUID employeeId;

    @BeforeAll
    static void migrateNonEmptyDatabase() throws Exception {
        POSTGRES.start();
        flyway("281").migrate();
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            try (ResultSet result = statement.executeQuery(
                    "SELECT id FROM employees ORDER BY id LIMIT 1")) {
                assertTrue(result.next());
                employeeId = result.getObject(1, UUID.class);
            }
        }
        assertEquals(1, flyway("282").migrate().migrationsExecuted);
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void ordinarySqlIsRejectedButControlledImportAndBackfillCanSetThenClear()
            throws Exception {
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            SQLException rejected = assertThrows(SQLException.class, () ->
                    statement.executeUpdate("""
                            UPDATE employees
                            SET huji_address = 'ordinary-plaintext-write'
                            WHERE id = '%s'
                            """.formatted(employeeId)));
            assertEquals("P0001", rejected.getSQLState());

            statement.execute("SELECT set_config('app.employee_pii_extra_legacy_import', 'v1', false)");
            assertEquals(1, statement.executeUpdate("""
                    UPDATE employees
                    SET huji_address = 'controlled-import'
                    WHERE id = '%s'
                    """.formatted(employeeId)));

            statement.execute("SELECT set_config('app.employee_pii_extra_legacy_import', '', false)");
            SQLException clearRejected = assertThrows(SQLException.class, () ->
                    statement.executeUpdate("""
                            UPDATE employees
                            SET huji_address = NULL
                            WHERE id = '%s'
                            """.formatted(employeeId)));
            assertEquals("P0001", clearRejected.getSQLState());

            statement.execute("SELECT set_config('app.employee_pii_extra_backfill', 'v1', false)");
            assertEquals(1, statement.executeUpdate("""
                    UPDATE employees
                    SET huji_address = NULL
                    WHERE id = '%s'
                    """.formatted(employeeId)));
        }
    }

    private static Flyway flyway(String target) {
        return Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target(target)
                .load();
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
}
