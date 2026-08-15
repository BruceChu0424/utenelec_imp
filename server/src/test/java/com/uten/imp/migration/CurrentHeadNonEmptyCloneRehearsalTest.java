package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationInfo;
import org.flywaydb.core.api.output.MigrateResult;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.sql.Connection;
import java.sql.DriverManager;

import com.uten.imp.migration.MigrationRehearsalSupport.Snapshot;

import static com.uten.imp.migration.MigrationRehearsalSupport.CURRENT_HEAD_VERSION;
import static com.uten.imp.migration.MigrationRehearsalSupport.CURRENT_MIGRATION_COUNT;
import static com.uten.imp.migration.MigrationRehearsalSupport.assertCurrentAuthority;
import static com.uten.imp.migration.MigrationRehearsalSupport.assertStableSnapshot;
import static com.uten.imp.migration.MigrationRehearsalSupport.clientSettlementIssueDigest;
import static com.uten.imp.migration.MigrationRehearsalSupport.identifierConflictDigest;
import static com.uten.imp.migration.MigrationRehearsalSupport.latestSuccessfulVersion;
import static com.uten.imp.migration.MigrationRehearsalSupport.snapshot;
import static com.uten.imp.migration.MigrationRehearsalSupport.successfulMigrationCount;
import static org.assertj.core.api.Assertions.assertThat;

/**
 * Destructively migrates an explicitly approved, recoverable company-data clone to the current
 * reviewed-candidate head. This never accepts the ordinary database name and never enables
 * Flyway clean. The database system identifier, backup digest, approval reference and reviewed
 * reconciliation digests bind the invocation to out-of-band evidence.
 */
@EnabledIfEnvironmentVariable(
        named = "UTEN_RUN_REHEARSAL_DB_TESTS",
        matches = "(?i)true")
class CurrentHeadNonEmptyCloneRehearsalTest {

    private static final String URL_ENV = "UTEN_REHEARSAL_DB_URL";
    private static final String USER_ENV = "UTEN_REHEARSAL_DB_USER";
    private static final String PASSWORD_ENV = "UTEN_REHEARSAL_DB_PASSWORD";
    private static final String EXPECTED_DATABASE_ENV = "UTEN_REHEARSAL_DB_EXPECTED_NAME";
    private static final String EXPECTED_START_ENV = "UTEN_REHEARSAL_DB_EXPECTED_START_VERSION";
    private static final String SYSTEM_IDENTIFIER_ENV =
            "UTEN_REHEARSAL_DB_SYSTEM_IDENTIFIER";
    private static final String BACKUP_SHA_ENV = "UTEN_REHEARSAL_BACKUP_SHA256";
    private static final String APPROVAL_ENV = "UTEN_REHEARSAL_APPROVAL_REFERENCE";
    private static final String IDENTIFIER_CONFLICT_SHA_ENV =
            "UTEN_REHEARSAL_IDENTIFIER_CONFLICT_SHA256";
    private static final String CLIENT_ISSUE_SHA_ENV =
            "UTEN_REHEARSAL_CLIENT_SETTLEMENT_ISSUE_SHA256";

    @Test
    void migratesApprovedRecoverableCloneToCurrentReviewedCandidate() throws Exception {
        String url = requiredEnv(URL_ENV);
        String user = requiredEnv(USER_ENV);
        String password = requiredEnv(PASSWORD_ENV);
        String expectedDatabase = requiredEnv(EXPECTED_DATABASE_ENV);
        String expectedStart = requiredEnv(EXPECTED_START_ENV);
        String expectedSystemIdentifier = requiredEnv(SYSTEM_IDENTIFIER_ENV);
        String backupSha = requiredEnv(BACKUP_SHA_ENV);
        String approvalReference = requiredEnv(APPROVAL_ENV);
        String expectedIdentifierConflictSha = requiredEnv(IDENTIFIER_CONFLICT_SHA_ENV);
        String expectedClientIssueSha = requiredEnv(CLIENT_ISSUE_SHA_ENV);

        assertThat(expectedStart).matches("[0-9]+");
        assertThat(Integer.parseInt(expectedStart)).isBetween(238, 288);
        assertThat(expectedSystemIdentifier).matches("[0-9]{10,32}");
        assertThat(backupSha).matches("(?i)[0-9a-f]{64}");
        assertThat(expectedIdentifierConflictSha).matches("(?i)[0-9a-f]{64}");
        assertThat(expectedClientIssueSha).matches("(?i)[0-9a-f]{64}");
        assertThat(approvalReference).matches("[A-Za-z0-9][A-Za-z0-9._:/-]{7,127}");

        Snapshot before;
        int installedBefore;
        try (Connection connection = DriverManager.getConnection(url, user, password)) {
            String database = scalarText(connection, "SELECT current_database()");
            assertThat(database)
                    .as("safety guard: use only the explicitly named disposable clone")
                    .isEqualTo(expectedDatabase)
                    .containsIgnoringCase("rehearsal")
                    .isNotEqualTo("uten_imp");
            assertThat(scalarText(connection,
                    "SELECT system_identifier::text FROM pg_control_system()"))
                    .as("safety guard: the clone must match the approved PostgreSQL cluster")
                    .isEqualTo(expectedSystemIdentifier);
            assertThat(latestSuccessfulVersion(connection)).isEqualTo(expectedStart);
            installedBefore = successfulMigrationCount(connection);
            before = snapshot(connection);
            assertThat(before.tableRows().get("users")).isPositive();
            assertThat(before.paymentTotals().activeCount())
                    .as("real-data rehearsal must exercise active historical payments")
                    .isPositive();
        }

        Flyway flyway = Flyway.configure()
                .dataSource(url, user, password)
                .locations("classpath:db/migration")
                .baselineOnMigrate(false)
                .cleanDisabled(true)
                .validateMigrationNaming(true)
                .target(CURRENT_HEAD_VERSION)
                .load();
        MigrationInfo[] pending = flyway.info().pending();
        assertThat(pending).isNotEmpty();
        assertThat(installedBefore + pending.length).isEqualTo(CURRENT_MIGRATION_COUNT);

        MigrateResult result = flyway.migrate();
        assertThat(result.targetSchemaVersion).isEqualTo(CURRENT_HEAD_VERSION);
        assertThat(result.migrationsExecuted).isEqualTo(pending.length);
        flyway.validate();

        try (Connection connection = DriverManager.getConnection(url, user, password)) {
            Snapshot after = snapshot(connection);
            assertStableSnapshot(before, after);
            assertCurrentAuthority(connection);
            assertThat(identifierConflictDigest(connection))
                    .isEqualToIgnoringCase(expectedIdentifierConflictSha);
            assertThat(clientSettlementIssueDigest(connection))
                    .isEqualToIgnoringCase(expectedClientIssueSha);
        }
    }

    private static String scalarText(Connection connection, String sql) throws Exception {
        try (var statement = connection.createStatement();
             var result = statement.executeQuery(sql)) {
            assertThat(result.next()).as("query returned a row: %s", sql).isTrue();
            return result.getString(1);
        }
    }

    private static String requiredEnv(String name) {
        String value = System.getenv(name);
        assertThat(value).as("required environment variable %s", name).isNotBlank();
        return value;
    }
}
