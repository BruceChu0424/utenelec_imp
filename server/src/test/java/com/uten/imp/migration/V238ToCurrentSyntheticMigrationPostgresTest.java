package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.output.MigrateResult;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.postgresql.PostgreSQLContainer;

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
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Preserves a real nonempty V238 chain up to the reviewed V424 boundary and refuses V425.
 * The complete current authority is checked separately on a genuinely fresh database.
 * Neither proof authorizes a historical company database to cross a destructive reset.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class V238ToCurrentSyntheticMigrationPostgresTest {

    private static final String BASELINE_VERSION = "238";

    private static final PostgreSQLContainer POSTGRES =
            new PostgreSQLContainer("postgres:16-alpine")
                    .withDatabaseName("uten_imp_rehearsal")
                    .withUsername("fixture_admin")
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
    void nonEmptyV238PreservesBusinessTotalsAndRefusesDestructiveAuditFreshStart()
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

        Flyway current = flyway(true, "424");
        assertThat(current.info().pending())
                .hasSize(MigrationRehearsalSupport.migrationFileCountUpTo(424) - installedBefore);
        MigrateResult result = current.migrate();
        assertThat(result.targetSchemaVersion).isEqualTo("424");
        assertThat(result.migrationsExecuted)
                .isEqualTo(MigrationRehearsalSupport.migrationFileCountUpTo(424) - installedBefore);
        current.validate();

        try (Connection connection = connection()) {
            assertThat(latestSuccessfulVersion(connection)).isEqualTo("424");
            Snapshot after = snapshot(connection);
            assertStableSnapshot(before, after);
            assertThatThrownBy(() -> flyway(true, CURRENT_HEAD_VERSION).migrate())
                    .isInstanceOf(org.flywaydb.core.api.FlywayException.class)
                    .hasStackTraceContaining("V425 audit fresh-start is allowed only");
            assertThat(snapshot(connection)).isEqualTo(after);
        }
    }

    @Test
    void genuinelyFreshInstallationRetainsTheCompleteCurrentAuthority() throws Exception {
        try (var fresh = new PostgreSQLContainer("postgres:16-alpine")
                .withDatabaseName("uten_current_authority")
                .withUsername("fixture_admin").withPassword("uten-test-only")) {
            fresh.start();
            var result = com.uten.imp.testsupport.TestFlyway.configure()
                    .dataSource(fresh.getJdbcUrl(), fresh.getUsername(), fresh.getPassword())
                    .locations("classpath:db/migration").load().migrate();
            assertThat(result.targetSchemaVersion).isEqualTo(CURRENT_HEAD_VERSION);
            assertThat(result.migrationsExecuted).isEqualTo(CURRENT_MIGRATION_COUNT);
            try (Connection connection = DriverManager.getConnection(
                    fresh.getJdbcUrl(), fresh.getUsername(), fresh.getPassword())) {
                assertCurrentAuthority(connection);
            }
        }
    }

    private static Flyway flyway(boolean cleanDisabled, String targetVersion) {
        return com.uten.imp.testsupport.TestFlyway.configure()
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
