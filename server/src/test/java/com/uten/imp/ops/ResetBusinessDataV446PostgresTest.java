package com.uten.imp.ops;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.MountableFile;

import java.nio.file.Path;
import java.sql.DriverManager;

import static org.assertj.core.api.Assertions.assertThat;

/** Real psql execution proof for the V446 reset-policy count gate. */
@Testcontainers(disabledWithoutDocker = true)
class ResetBusinessDataV446PostgresTest {

    private static final String SCRIPT_IN_CONTAINER =
            "/tmp/reset_business_data.sql";

    @Container
    static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16.15-alpine")
                    .withDatabaseName("uten_reset_v446")
                    .withUsername("uten")
                    .withPassword("uten")
                    .withCopyFileToContainer(
                            MountableFile.forHostPath(Path.of(
                                    "ops/reset_business_data.sql").toAbsolutePath()),
                            SCRIPT_IN_CONTAINER);

    @Test
    void currentV446CatalogPassesTheFailClosedResetPolicyAndExecutes() throws Exception {
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();

        String systemIdentifier;
        try (var connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
             var statement = connection.createStatement();
             var rows = statement.executeQuery(
                     "SELECT system_identifier::text FROM pg_control_system()")) {
            assertThat(rows.next()).isTrue();
            systemIdentifier = rows.getString(1);
        }

        var result = POSTGRES.execInContainer(
                "psql", "-X", "-U", POSTGRES.getUsername(),
                "-d", POSTGRES.getDatabaseName(),
                "-v", "ON_ERROR_STOP=1",
                "-v", "confirm=CLEAR_BUSINESS",
                "-v", "expected_database=" + POSTGRES.getDatabaseName(),
                "-v", "expected_system_identifier=" + systemIdentifier,
                "-f", SCRIPT_IN_CONTAINER);

        assertThat(result.getExitCode())
                .withFailMessage("reset psql failed:%n%s%n%s",
                        result.getStdout(), result.getStderr())
                .isZero();
        try (var connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
             var statement = connection.createStatement();
             var rows = statement.executeQuery("""
                     SELECT
                       (SELECT count(*) FROM procurement_iqc_stock_in_batches),
                       (SELECT count(*) FROM procurement_iqc_stock_in_batch_items),
                       (SELECT count(*) FROM flyway_schema_history)
                     """)) {
            assertThat(rows.next()).isTrue();
            assertThat(rows.getLong(1)).isZero();
            assertThat(rows.getLong(2)).isZero();
            assertThat(rows.getLong(3)).isPositive();
        }
    }
}
