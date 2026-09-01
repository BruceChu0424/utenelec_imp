package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationVersion;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementIqcRejectionFinanceClosurePostgresTest {

    private static final String EMPTY_DB = "uten_v440_empty";
    private static final String EXISTING_DB = "uten_v440_existing";
    private static final String PARTIAL_FAIL_DB = "uten_v440_partial_fail";
    private static final String RESOLVED_FAIL_DB = "uten_v440_resolved_fail";
    private static final UUID STABLE_SURFACE_ID =
            UUID.fromString("44000000-0000-4000-8000-000000000001");
    private static final UUID EXISTING_SURFACE_ID =
            UUID.fromString("aaaaaaaa-0000-4000-8000-000000000440");

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_admin")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    @BeforeAll
    static void start() {
        POSTGRES.start();
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void v440CreatesStableSurfaceAndRejectsPreexistingBusinessKeyDrift()
            throws Exception {
        createDatabase(EMPTY_DB, null);
        migrate(EMPTY_DB, "439");
        createDatabase(EXISTING_DB, EMPTY_DB);
        try (Connection connection = connection(EXISTING_DB);
             PreparedStatement insert = connection.prepareStatement("""
                     INSERT INTO permission_surfaces(
                         id,surface_key,name,sort_order,enabled)
                     VALUES(?, 'procurement.iqc-rejection',
                            '既有IQC闭环目录', 999, FALSE)
                     """)) {
            insert.setObject(1, EXISTING_SURFACE_ID);
            insert.executeUpdate();
        }

        migrate(EMPTY_DB, "440");
        assertThatThrownBy(() -> migrate(EXISTING_DB, "440"))
                .hasMessageContaining("surface identity conflicts");

        assertSurface(
                EMPTY_DB,
                STABLE_SURFACE_ID,
                "采购/委外 IQC 不合格闭环",
                265,
                true);
        assertSurface(
                EXISTING_DB,
                EXISTING_SURFACE_ID,
                "既有IQC闭环目录",
                999,
                false);
        assertThat(permissionLinks(EMPTY_DB)).isEqualTo(7);
        assertThat(permissionLinks(EXISTING_DB)).isZero();
        assertThat(appliedV440(EMPTY_DB)).isEqualTo(1);
        assertThat(appliedV440(EXISTING_DB)).isZero();
    }

    @Test
    void v440RollsBackBeforeHoldsForHistoricalPartialOrResolvedFailure()
            throws Exception {
        for (String database : new String[]{PARTIAL_FAIL_DB, RESOLVED_FAIL_DB}) {
            createDatabase(database, null);
            migrate(database, "439");
            insertHistoricalFailure(
                    database,
                    database.equals(PARTIAL_FAIL_DB) ? "PARTIAL" : "RESOLVED");

            assertThatThrownBy(() -> migrate(database, "440"))
                    .hasMessageContaining(
                            "requires reconciliation of historical partial/resolved IQC failures");
            assertThat(appliedV440(database)).isZero();
            assertThat(scalar(database, """
                    SELECT COUNT(*) FROM pg_class
                    WHERE relname='procurement_iqc_rejection_cases'
                    """)).isZero();
            assertThat(scalar(database, """
                    SELECT COUNT(*) FROM pg_trigger
                    WHERE tgname='trg_00_guard_procurement_iqc_ap_mutation'
                    """)).isZero();
        }
    }

    private static void insertHistoricalFailure(String database, String status)
            throws Exception {
        try (Connection connection = connection(database);
             Statement statement = connection.createStatement()) {
            statement.execute("SET session_replication_role=replica");
            String passed = status.equals("RESOLVED") ? "8" : "0";
            statement.execute("""
                    INSERT INTO procurement_inspection_items(
                        id,receipt_type,receipt_id,receipt_item_id,
                        warehouse_id,goods_id,unit_rate,received_base_qty,
                        received_amount_local,passed_base_qty,failed_base_qty,status)
                    VALUES(
                        '44000000-0000-4000-9000-000000000001',
                        'PURCHASE',
                        '44000000-0000-4000-9000-000000000002',
                        '44000000-0000-4000-9000-000000000003',
                        '44000000-0000-4000-9000-000000000004',
                        '44000000-0000-4000-9000-000000000005',
                        1,10,10,%s,2,'%s')
                    """.formatted(passed,status));
            statement.execute("SET session_replication_role=origin");
        }
    }

    private static void createDatabase(String database, String template)
            throws Exception {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            statement.execute("CREATE DATABASE " + database
                    + (template == null ? "" : " TEMPLATE " + template));
        }
    }

    private static void migrate(String database, String target) {
        Flyway.configure()
                .dataSource(
                        jdbcUrl(database),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target(MigrationVersion.fromVersion(target))
                .load()
                .migrate();
    }

    private static void assertSurface(
            String database,
            UUID expectedId,
            String expectedName,
            int expectedSortOrder,
            boolean expectedEnabled) throws Exception {
        try (Connection connection = connection(database);
             PreparedStatement query = connection.prepareStatement("""
                     SELECT id,name,sort_order,enabled
                     FROM permission_surfaces
                     WHERE surface_key='procurement.iqc-rejection'
                     """);
             ResultSet rows = query.executeQuery()) {
            assertThat(rows.next()).isTrue();
            assertThat(rows.getObject(1, UUID.class)).isEqualTo(expectedId);
            assertThat(rows.getString(2)).isEqualTo(expectedName);
            assertThat(rows.getInt(3)).isEqualTo(expectedSortOrder);
            assertThat(rows.getBoolean(4)).isEqualTo(expectedEnabled);
            assertThat(rows.next()).isFalse();
        }
    }

    private static long permissionLinks(String database) throws Exception {
        return scalar(database, """
                SELECT COUNT(*)
                FROM permission_surface_permissions link
                JOIN permission_surfaces surface ON surface.id=link.surface_id
                JOIN permissions permission ON permission.id=link.permission_id
                WHERE surface.surface_key='procurement.iqc-rejection'
                  AND permission.code LIKE 'procurement_iqc_rejection:%'
                """);
    }

    private static long appliedV440(String database) throws Exception {
        return scalar(database, """
                SELECT COUNT(*) FROM flyway_schema_history
                WHERE version='440' AND success
                """);
    }

    private static long scalar(String database, String sql) throws Exception {
        try (Connection connection = connection(database);
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery(sql)) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private static Connection connection(String database) throws Exception {
        return DriverManager.getConnection(
                jdbcUrl(database),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private static String jdbcUrl(String database) {
        return "jdbc:postgresql://" + POSTGRES.getHost() + ":"
                + POSTGRES.getMappedPort(PostgreSQLContainer.POSTGRESQL_PORT)
                + "/" + database;
    }
}
