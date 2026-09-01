package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;

import static org.assertj.core.api.Assertions.assertThat;

@EnabledIfEnvironmentVariable(
        named = "UTEN_RUN_DB_TESTS",
        matches = "(?i)true")
class LegacyMeasurementProfileInferencePostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp_measurement_inference")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void manifestBoundInferenceScriptExecutesOnEmptyImportedModules()
            throws Exception {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            statement.executeUpdate("""
                    INSERT INTO legacy_migration_runs(
                        target,
                        status,
                        migration_mode,
                        export_manifest_sha256,
                        checksum_manifest_sha256,
                        source_backup_sha256,
                        export_approval_reference,
                        migration_repository_commit,
                        mapping_version)
                    VALUES (
                        '--bootstrap-all',
                        'RUNNING',
                        'BOOTSTRAP',
                        repeat('a', 64),
                        repeat('b', 64),
                        repeat('c', 64),
                        'measurement-test-approval',
                        repeat('d', 40),
                        'measurement-test-v1')
                    """);

            Path direct = Path.of(
                    "legacy_migration",
                    "migrate_measurement_profiles.sql");
            Path script = Files.exists(direct)
                    ? direct : Path.of("server").resolve(direct);
            Path stagedDirectory = Files.createTempDirectory(
                    "uten-measurement-inference-");
            Path staged = stagedDirectory.resolve(
                    "V9999__legacy_measurement_profile_inference_test.sql");
            try {
                Files.copy(script, staged);
                Flyway.configure()
                        .dataSource(
                                POSTGRES.getJdbcUrl(),
                                POSTGRES.getUsername(),
                                POSTGRES.getPassword())
                        .locations(
                                "classpath:db/migration",
                                "filesystem:"
                                        + stagedDirectory.toAbsolutePath())
                        .load()
                        .migrate();
            } finally {
                Files.deleteIfExists(staged);
                Files.deleteIfExists(stagedDirectory);
            }

            assertThat(count(statement,
                    "SELECT COUNT(*) FROM legacy_measurement_profile_snapshots"))
                    .isZero();
            assertThat(count(statement,
                    "SELECT COUNT(*) FROM measurement_capture_profiles"))
                    .isZero();
            assertThat(count(statement,
                    "SELECT COUNT(*) FROM legacy_measurement_exceptions"))
                    .isZero();
        }
    }

    private static long count(Statement statement, String sql)
            throws Exception {
        try (ResultSet rows = statement.executeQuery(sql)) {
            assertThat(rows.next()).isTrue();
            return rows.getLong(1);
        }
    }
}
