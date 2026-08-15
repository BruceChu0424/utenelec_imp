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
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Non-empty V273 -> V274 rehearsal for warehouse workshop UUID authority. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WarehouseWorkshopUuidPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static UUID workshopId;
    private static UUID productionDepartmentId;
    private static UUID warehouseId;
    private static UUID zeroWarehouseId;
    private static int migrationsExecuted;

    @BeforeAll
    static void migrateToV273AndSeedReviewedCrosswalk() throws Exception {
        POSTGRES.start();
        flyway("273").migrate();

        warehouseId = UUID.randomUUID();
        zeroWarehouseId = UUID.randomUUID();
        try (Connection connection = connection()) {
            productionDepartmentId = uuidByCode(connection, "DEPT_PROD");
            workshopId = uuidByCode(connection, "WS_ZHUSU");

            // A reviewed crosswalk may be preloaded before an upgrade. V274
            // owns its constraints/triggers and consumes only this exact-ID
            // bridge; it never guesses from warehouse/workshop names.
            try (Statement statement = connection.createStatement()) {
                statement.executeUpdate("""
                        CREATE TABLE legacy_warehouse_workshop_links (
                            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                            warehouse_legacy_id INT NOT NULL UNIQUE,
                            workshop_department_id UUID NOT NULL,
                            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                            updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
                        )
                        """);
            }
            try (PreparedStatement link = connection.prepareStatement("""
                    INSERT INTO legacy_warehouse_workshop_links (
                        warehouse_legacy_id, workshop_department_id)
                    VALUES (974001, ?)
                    """)) {
                link.setObject(1, workshopId);
                assertEquals(1, link.executeUpdate());
            }
            try (PreparedStatement warehouse = connection.prepareStatement("""
                    INSERT INTO warehouses (
                        id, legacy_id, code, name, is_accountable,
                        workshop_legacy_id, status, auto_created, is_deleted)
                    VALUES (?, 974001, 'WH-V274', 'V274 reviewed warehouse',
                            true, 135, '使用', false, false)
                    """)) {
                warehouse.setObject(1, warehouseId);
                assertEquals(1, warehouse.executeUpdate());
            }
            try (PreparedStatement warehouse = connection.prepareStatement("""
                    INSERT INTO warehouses (
                        id, legacy_id, code, name, is_accountable,
                        workshop_legacy_id, status, auto_created, is_deleted)
                    VALUES (?, 974002, 'WH-V274-ZERO', 'V274 zero sentinel',
                            true, 0, '使用', false, false)
                    """)) {
                warehouse.setObject(1, zeroWarehouseId);
                assertEquals(1, warehouse.executeUpdate());
            }
        }
        migrationsExecuted = flyway("274").migrate().migrationsExecuted;
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void v274BackfillsOnlyExactWarehouseBridgeAndCorrectsOperatorShadow()
            throws Exception {
        assertEquals(1, migrationsExecuted);

        try (Connection connection = connection()) {
            assertEquals(workshopId, uuid(connection,
                    "SELECT workshop_department_id FROM warehouses WHERE id=?",
                    warehouseId));
            assertEquals(135, integer(connection,
                    "SELECT legacy_operator_id FROM warehouses WHERE id=?",
                    warehouseId));
            assertEquals(135, integer(connection,
                    "SELECT workshop_legacy_id FROM warehouses WHERE id=?",
                    warehouseId));
            assertNull(object(connection,
                    "SELECT workshop_department_id FROM warehouses WHERE id=?",
                    zeroWarehouseId));
            assertNull(object(connection,
                    "SELECT legacy_operator_id FROM warehouses WHERE id=?",
                    zeroWarehouseId));
            assertEquals(2, scalar(connection, """
                    SELECT count(*) FROM pg_constraint
                    WHERE conname IN (
                        'fk_warehouses_workshop_department',
                        'fk_legacy_warehouse_workshop_department')
                      AND convalidated
                    """));
            assertEquals(2, scalar(connection, """
                    SELECT count(*)
                    FROM pg_trigger trigger
                    JOIN pg_proc function ON function.oid = trigger.tgfoid
                    WHERE trigger.tgname IN (
                        'trg_audit_warehouses',
                        'trg_audit_legacy_warehouse_workshop_links')
                      AND function.proname = 'fn_audit'
                      AND NOT trigger.tgisinternal
                    """));
        }
    }

    @Test
    void databaseRejectsNonWorkshopReferencesAndProtectsDepartmentDeletion()
            throws Exception {
        SQLException nonWorkshop = assertThrows(SQLException.class, () -> {
            try (Connection connection = connection();
                 PreparedStatement update = connection.prepareStatement("""
                         UPDATE warehouses
                         SET workshop_department_id=?
                         WHERE id=?
                         """)) {
                update.setObject(1, productionDepartmentId);
                update.setObject(2, warehouseId);
                update.executeUpdate();
            }
        });
        assertEquals("23514", nonWorkshop.getSQLState());

        SQLException softDelete = assertThrows(SQLException.class, () -> {
            try (Connection connection = connection();
                 PreparedStatement update = connection.prepareStatement("""
                         UPDATE departments SET is_deleted=true WHERE id=?
                         """)) {
                update.setObject(1, workshopId);
                update.executeUpdate();
            }
        });
        assertEquals("23503", softDelete.getSQLState());

        SQLException hardDelete = assertThrows(SQLException.class, () -> {
            try (Connection connection = connection();
                 PreparedStatement delete = connection.prepareStatement(
                         "DELETE FROM departments WHERE id=?")) {
                delete.setObject(1, workshopId);
                delete.executeUpdate();
            }
        });
        assertEquals("23503", hardDelete.getSQLState());
    }

    @Test
    void oldAndCanonicalOperatorShadowsRemainSynchronized() throws Exception {
        try (Connection connection = connection()) {
            UUID shadowWarehouseId = UUID.randomUUID();
            try (PreparedStatement insert = connection.prepareStatement("""
                    INSERT INTO warehouses (
                        id, code, name, is_accountable, workshop_department_id,
                        workshop_legacy_id, status, auto_created, is_deleted)
                    VALUES (?, ?, 'V274 shadow synchronization', true, ?,
                            135, '使用', false, false)
                    """)) {
                insert.setObject(1, shadowWarehouseId);
                insert.setString(2, "WH-V274-SHADOW-"
                        + shadowWarehouseId.toString().substring(0, 8));
                insert.setObject(3, workshopId);
                assertEquals(1, insert.executeUpdate());
            }
            try (PreparedStatement oldWriter = connection.prepareStatement("""
                    UPDATE warehouses SET workshop_legacy_id=177 WHERE id=?
                    """)) {
                oldWriter.setObject(1, shadowWarehouseId);
                assertEquals(1, oldWriter.executeUpdate());
            }
            assertEquals(177, integer(connection,
                    "SELECT legacy_operator_id FROM warehouses WHERE id=?",
                    shadowWarehouseId));

            try (PreparedStatement canonicalWriter = connection.prepareStatement("""
                    UPDATE warehouses SET legacy_operator_id=174 WHERE id=?
                    """)) {
                canonicalWriter.setObject(1, shadowWarehouseId);
                assertEquals(1, canonicalWriter.executeUpdate());
            }
            assertEquals(174, integer(connection,
                    "SELECT workshop_legacy_id FROM warehouses WHERE id=?",
                    shadowWarehouseId));
        }
    }

    private static UUID uuidByCode(Connection connection, String code) throws Exception {
        try (PreparedStatement query = connection.prepareStatement(
                "SELECT id FROM departments WHERE code=?")) {
            query.setString(1, code);
            try (ResultSet result = query.executeQuery()) {
                assertTrue(result.next());
                return result.getObject(1, UUID.class);
            }
        }
    }

    private static UUID uuid(Connection connection, String sql, UUID id) throws Exception {
        Object value = object(connection, sql, id);
        return (UUID) value;
    }

    private static int integer(Connection connection, String sql, UUID id) throws Exception {
        Object value = object(connection, sql, id);
        return ((Number) value).intValue();
    }

    private static Object object(Connection connection, String sql, UUID id) throws Exception {
        try (PreparedStatement query = connection.prepareStatement(sql)) {
            query.setObject(1, id);
            try (ResultSet result = query.executeQuery()) {
                assertTrue(result.next());
                return result.getObject(1);
            }
        }
    }

    private static int scalar(Connection connection, String sql) throws Exception {
        try (Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            assertTrue(result.next());
            return result.getInt(1);
        }
    }

    private static Flyway flyway(String target) {
        return Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target(target)
                .load();
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
}
