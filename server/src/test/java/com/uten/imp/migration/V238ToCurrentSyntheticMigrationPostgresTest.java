package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.output.MigrateResult;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Statement;

import com.uten.imp.migration.MigrationRehearsalSupport.Snapshot;

import static com.uten.imp.migration.MigrationRehearsalSupport.CURRENT_HEAD_VERSION;
import static com.uten.imp.migration.MigrationRehearsalSupport.CURRENT_MIGRATION_COUNT;
import static com.uten.imp.migration.MigrationRehearsalSupport.assertCurrentAuthority;
import static com.uten.imp.migration.MigrationRehearsalSupport.assertStableSnapshot;
import static com.uten.imp.migration.MigrationRehearsalSupport.latestSuccessfulVersion;
import static com.uten.imp.migration.MigrationRehearsalSupport.snapshot;
import static com.uten.imp.migration.MigrationRehearsalSupport.successfulMigrationCount;
import static org.assertj.core.api.Assertions.assertThat;

/**
 * Replays the current reviewed-candidate migration set from the last recorded company schema
 * baseline. The V238 schema already contains system and administrator rows, so this catches
 * upgrade-only failures that an empty V1-to-head replay cannot expose. Real company history still
 * requires a separately approved, recoverable clone rehearsal.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class V238ToCurrentSyntheticMigrationPostgresTest {

    private static final String BASELINE_VERSION = "238";

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp_rehearsal")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    @BeforeAll
    static void startDatabase() {
        POSTGRES.start();
}
    @AfterAll
    static void stopDatabase() {
        POSTGRES.stop();
    }

    @Test
    void migratesNonEmptyV238SchemaToCurrentHeadWithoutChangingBusinessTotals()
            throws Exception {
        Flyway baseline = flyway(false, BASELINE_VERSION);
        baseline.clean();
        MigrateResult baselineResult = baseline.migrate();
        assertThat(baselineResult.targetSchemaVersion).isEqualTo(BASELINE_VERSION);

        Snapshot before;
        int installedBefore;
        try (Connection connection = connection()) {
            assertThat(latestSuccessfulVersion(connection)).isEqualTo(BASELINE_VERSION);
            installedBefore = successfulMigrationCount(connection);
            assertThat(installedBefore).isPositive().isLessThan(CURRENT_MIGRATION_COUNT);
            seedV238Fixture(connection);
            before = snapshot(connection);
            assertThat(before.tableRows().get("departments")).isPositive();
            assertThat(before.tableRows().get("permissions")).isPositive();
            assertThat(before.tableRows().get("employees")).isPositive();
            assertThat(before.tableRows().get("users")).isPositive();
        }

        Flyway current = flyway(true, CURRENT_HEAD_VERSION);
        assertThat(current.info().pending())
                .hasSize(CURRENT_MIGRATION_COUNT - installedBefore);
        MigrateResult result = current.migrate();
        assertThat(result.targetSchemaVersion).isEqualTo(CURRENT_HEAD_VERSION);
        assertThat(result.migrationsExecuted).isEqualTo(CURRENT_MIGRATION_COUNT - installedBefore);
        current.validate();

        try (Connection connection = connection()) {
            assertThat(latestSuccessfulVersion(connection)).isEqualTo(CURRENT_HEAD_VERSION);
            Snapshot after = snapshot(connection);
            assertStableSnapshot(before, after);
            assertCurrentAuthority(connection);
        }
    }

    private static Flyway flyway(boolean cleanDisabled, String targetVersion) {
        return Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .baselineOnMigrate(false)
                .cleanDisabled(cleanDisabled)
                .validateMigrationNaming(true)
                .target(targetVersion)
                .load();
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private static void seedV238Fixture(Connection connection) throws SQLException {
        try (Statement statement = connection.createStatement()) {
            int inserted = statement.executeUpdate("""
                    INSERT INTO users (
                        employee_id, login_account, password_hash,
                        must_change_password, status)
                    SELECT id, 'migration-rehearsal', 'test-only-non-login-hash', TRUE, 'active'
                    FROM employees
                    WHERE code = 'ADMIN'
                    """);
            assertThat(inserted).isEqualTo(1);
        }
    }

}
