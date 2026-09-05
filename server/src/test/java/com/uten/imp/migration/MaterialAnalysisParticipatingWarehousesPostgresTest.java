package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.Arrays;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

@Testcontainers(disabledWithoutDocker = true)
class MaterialAnalysisParticipatingWarehousesPostgresTest {

    @Container
    static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16.15-alpine")
                    .withDatabaseName("material_analysis_warehouses_v471")
                    .withUsername("uten")
                    .withPassword("uten");

    @Test
    void backfillsPrimaryAndRejectsMissingDuplicateOrInactiveParticipants()
            throws Exception {
        migrate("470");
        UUID analysisId = UUID.randomUUID();
        UUID primary = UUID.randomUUID();
        UUID secondary = UUID.randomUUID();
        UUID inactive = UUID.randomUUID();

        try (Connection connection = connection()) {
            UUID employeeId = scalarUuid(connection,
                    "SELECT id FROM employees ORDER BY id LIMIT 1");
            insertWarehouse(connection, primary, "MW-PRIMARY", "主领料仓", "使用");
            insertWarehouse(connection, secondary, "MW-SECONDARY", "参与仓", "使用");
            insertWarehouse(connection, inactive, "MW-INACTIVE", "禁用仓", "禁用");
            try (var statement = connection.prepareStatement("""
                    INSERT INTO production_material_analyses(
                        id, warehouse_id, fingerprint, initial_idempotency_key,
                        maker_id)
                    VALUES (?, ?, ?, ?, ?)
                    """)) {
                statement.setObject(1, analysisId);
                statement.setObject(2, primary);
                statement.setString(3, "a".repeat(64));
                statement.setString(4, "v471-existing-analysis");
                statement.setObject(5, employeeId);
                statement.executeUpdate();
            }
        }

        migrate("471");
        try (Connection connection = connection()) {
            assertThat(selectedWarehouses(connection, analysisId))
                    .containsExactly(primary);

            UUID legacyWriterAnalysisId = UUID.randomUUID();
            UUID employeeId = scalarUuid(connection,
                    "SELECT id FROM employees ORDER BY id LIMIT 1");
            try (var statement = connection.prepareStatement("""
                    INSERT INTO production_material_analyses(
                        id, warehouse_id, fingerprint, initial_idempotency_key,
                        maker_id)
                    VALUES (?, ?, ?, ?, ?)
                    """)) {
                statement.setObject(1, legacyWriterAnalysisId);
                statement.setObject(2, primary);
                statement.setString(3, "b".repeat(64));
                statement.setString(4, "v471-legacy-writer");
                statement.setObject(5, employeeId);
                statement.executeUpdate();
            }
            assertThat(selectedWarehouses(connection, legacyWriterAnalysisId))
                    .containsExactly(primary);

            updateWarehouses(connection, analysisId, primary,
                    new UUID[]{primary, secondary});
            assertThat(selectedWarehouses(connection, analysisId))
                    .containsExactlyInAnyOrder(primary, secondary);

            SQLException missingPrimary = assertThrows(SQLException.class,
                    () -> updateWarehouses(connection, analysisId, primary,
                            new UUID[]{secondary}));
            assertThat(missingPrimary.getSQLState()).isEqualTo("23514");

            SQLException duplicate = assertThrows(SQLException.class,
                    () -> updateWarehouses(connection, analysisId, primary,
                            new UUID[]{primary, primary}));
            assertThat(duplicate.getSQLState()).isEqualTo("23514");

            SQLException disabled = assertThrows(SQLException.class,
                    () -> updateWarehouses(connection, analysisId, primary,
                            new UUID[]{primary, inactive}));
            assertThat(disabled.getSQLState()).isEqualTo("23514");
        }
    }

    private static void migrate(String target) {
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target(target)
                .load()
                .migrate();
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private static void insertWarehouse(
            Connection connection, UUID id, String code, String name,
            String status) throws SQLException {
        try (var statement = connection.prepareStatement("""
                INSERT INTO warehouses(id, code, name, status, is_accountable)
                VALUES (?, ?, ?, ?, TRUE)
                """)) {
            statement.setObject(1, id);
            statement.setString(2, code);
            statement.setString(3, name);
            statement.setString(4, status);
            statement.executeUpdate();
        }
    }

    private static void updateWarehouses(
            Connection connection, UUID analysisId, UUID primary,
            UUID[] warehouses) throws SQLException {
        try (var statement = connection.prepareStatement("""
                UPDATE production_material_analyses
                SET warehouse_id = ?, participating_warehouse_ids = ?
                WHERE id = ?
                """)) {
            statement.setObject(1, primary);
            statement.setArray(2, connection.createArrayOf("uuid", warehouses));
            statement.setObject(3, analysisId);
            statement.executeUpdate();
        }
    }

    private static UUID[] selectedWarehouses(
            Connection connection, UUID analysisId) throws SQLException {
        try (var statement = connection.prepareStatement("""
                SELECT participating_warehouse_ids
                FROM production_material_analyses WHERE id = ?
                """)) {
            statement.setObject(1, analysisId);
            try (var result = statement.executeQuery()) {
                result.next();
                Object[] raw = (Object[]) result.getArray(1).getArray();
                return Arrays.stream(raw)
                        .map(value -> value instanceof UUID id
                                ? id : UUID.fromString(value.toString()))
                        .toArray(UUID[]::new);
            }
        }
    }

    private static UUID scalarUuid(Connection connection, String sql)
            throws SQLException {
        try (var statement = connection.createStatement();
             var result = statement.executeQuery(sql)) {
            result.next();
            return result.getObject(1, UUID.class);
        }
    }
}
