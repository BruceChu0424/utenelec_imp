package com.uten.imp.features.production.analysis;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.time.LocalDate;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

/** PostgreSQL evidence for V234 conservation and deferred aggregate guards. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionMaterialAnalysisPersistencePostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void planLifecycleMovesSubmittedToApprovedAndReverseRestoresAnalysis() throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = fixture(connection, new BigDecimal("4.0000"));
            UUID linkId = UUID.randomUUID();
            insert(connection, """
                    INSERT INTO production_material_analysis_plan_links(
                        id,analysis_id,analysis_item_id,plan_id,
                        submitted_qty,allocation_status,created_by
                    ) VALUES(?,?,?,?,4,'SUBMITTED',?)
                    """, linkId, fixture.analysisId(), fixture.itemId(),
                    fixture.planId(), fixture.userId());

            assertQuantities(connection, fixture.itemId(), "4.0000", "0.0000");
            assertText(connection, """
                    SELECT status FROM production_material_analyses WHERE id=?
                    """, fixture.analysisId(), "COMPLETED");
            assertText(connection, """
                    SELECT allocation_status
                    FROM production_material_analysis_plan_links WHERE id=?
                    """, linkId, "SUBMITTED");

            update(connection, "UPDATE production_plans SET status=1 WHERE id=?",
                    fixture.planId());
            assertQuantities(connection, fixture.itemId(), "0.0000", "4.0000");
            assertText(connection, """
                    SELECT allocation_status
                    FROM production_material_analysis_plan_links WHERE id=?
                    """, linkId, "APPROVED");
            assertText(connection, """
                    SELECT status FROM production_material_analyses WHERE id=?
                    """, fixture.analysisId(), "COMPLETED");

            update(connection, "UPDATE production_plans SET status=-1 WHERE id=?",
                    fixture.planId());
            assertQuantities(connection, fixture.itemId(), "0.0000", "0.0000");
            assertText(connection, """
                    SELECT allocation_status
                    FROM production_material_analysis_plan_links WHERE id=?
                    """, linkId, "REVERSED");
            assertText(connection, """
                    SELECT status FROM production_material_analyses WHERE id=?
                    """, fixture.analysisId(), "ACTIVE");
        }
    }

    @Test
    void releasingDraftInvalidatesCasAndZerosConservativeReadiness() throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = fixture(connection, new BigDecimal("10.0000"),
                    new BigDecimal("4.0000"));
            update(connection, """
                    UPDATE production_material_analysis_items
                    SET ready_now_qty=10, ready_by_date_qty=10 WHERE id=?
                    """, fixture.itemId());
            UUID linkId = UUID.randomUUID();
            insert(connection, """
                    INSERT INTO production_material_analysis_plan_links(
                        id,analysis_id,analysis_item_id,plan_id,
                        submitted_qty,allocation_status,created_by
                    ) VALUES(?,?,?,?,4,'SUBMITTED',?)
                    """, linkId, fixture.analysisId(), fixture.itemId(),
                    fixture.planId(), fixture.userId());
            String fingerprintBeforeRelease = scalarText(connection,
                    "SELECT fingerprint FROM production_material_analyses WHERE id=?",
                    fixture.analysisId());
            long versionBeforeRelease = scalarLong(connection,
                    "SELECT version FROM production_material_analyses WHERE id=?",
                    fixture.analysisId());

            update(connection, "UPDATE production_plans SET is_deleted=TRUE WHERE id=?",
                    fixture.planId());

            assertQuantities(connection, fixture.itemId(), "0.0000", "0.0000");
            assertReady(connection, fixture.itemId(), "0.0000", "0.0000");
            assertEquals("ACTIVE", scalarText(connection,
                    "SELECT status FROM production_material_analyses WHERE id=?",
                    fixture.analysisId()));
            assertEquals(versionBeforeRelease + 1, scalarLong(connection,
                    "SELECT version FROM production_material_analyses WHERE id=?",
                    fixture.analysisId()));
            org.junit.jupiter.api.Assertions.assertNotEquals(fingerprintBeforeRelease,
                    scalarText(connection,
                            "SELECT fingerprint FROM production_material_analyses WHERE id=?",
                            fixture.analysisId()));
        }
    }

    @Test
    void deferredSupplyActionAllocationMustExactlyEqualHeaderQuantity() throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = fixture(connection, new BigDecimal("10.0000"));
            UUID materialId = UUID.randomUUID();
            insert(connection, """
                    INSERT INTO production_material_analysis_materials(
                        id,analysis_id,analysis_item_id,node_key,goods_id,unit_id,
                        depth,path,per_product_qty,required_qty,source_suggestion
                    ) VALUES(?,?,?,?,?,?,1,?,1,10,'BUY')
                    """, materialId, fixture.analysisId(), fixture.itemId(),
                    "node-" + materialId, fixture.goodsId(), fixture.unitId(),
                    "node-" + materialId);

            UUID validAction = UUID.randomUUID();
            connection.setAutoCommit(false);
            try {
                insertAction(connection, fixture, validAction, "5.0000");
                insertAllocation(connection, fixture, materialId, validAction, "5.0000");
                connection.commit();
            } catch (Throwable error) {
                connection.rollback();
                throw error;
            } finally {
                connection.setAutoCommit(true);
            }

            UUID invalidAction = UUID.randomUUID();
            connection.setAutoCommit(false);
            try {
                insertAction(connection, fixture, invalidAction, "5.0000");
                insertAllocation(connection, fixture, materialId, invalidAction, "4.0000");
                PSQLException failure = assertThrows(PSQLException.class, connection::commit);
                assertEquals("23514", failure.getSQLState());
                connection.rollback();
            } finally {
                if (!connection.getAutoCommit()) {
                    connection.rollback();
                    connection.setAutoCommit(true);
                }
            }
        }
    }

    @Test
    void manualSourceReferenceIsRequiredAndUniqueIgnoringCaseAndWhitespace() throws Exception {
        try (Connection connection = connection()) {
            String sourceRef = "REQ-" + UUID.randomUUID();
            Fixture fixture = fixture(connection, new BigDecimal("10.0000"),
                    new BigDecimal("10.0000"), sourceRef);

            PSQLException missing = assertThrows(PSQLException.class, () -> update(connection,
                    "UPDATE production_material_analysis_items SET source_ref=NULL WHERE id=?",
                    fixture.itemId()));
            assertEquals("23514", missing.getSQLState());

            PSQLException duplicate = assertThrows(PSQLException.class, () -> fixture(
                    connection, new BigDecimal("3.0000"), new BigDecimal("3.0000"),
                    "  " + sourceRef.toLowerCase() + "  "));
            assertEquals("23505", duplicate.getSQLState());
        }
    }

    @Test
    void analysisPlanItemIdentityAndQuantityAreImmutableAtTheDatabaseBoundary()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = fixture(connection, new BigDecimal("10.0000"),
                    new BigDecimal("4.0000"));

            PSQLException insertFailure = assertThrows(PSQLException.class, () -> insert(
                    connection, """
                            INSERT INTO production_plan_items(
                                id,bill_no,bill_date,plan_id,line_no,product_no,
                                goods_id,unit_id,unit_rate,qty,created_by,updated_by
                            ) VALUES(?,?,?,?,2,?,?,?,1,1,?,?)
                            """, UUID.randomUUID(), "V234-EXTRA-" + fixture.planId(),
                    LocalDate.of(2026, 8, 8), fixture.planId(),
                    "V234-EXTRA-PI-" + fixture.planId(), fixture.goodsId(),
                    fixture.unitId(), fixture.userId(), fixture.userId()));
            assertEquals("55000", insertFailure.getSQLState());

            PSQLException updateFailure = assertThrows(PSQLException.class, () -> update(
                    connection, "UPDATE production_plan_items SET qty=5 WHERE plan_id=?",
                    fixture.planId()));
            assertEquals("55000", updateFailure.getSQLState());

            PSQLException deleteFailure = assertThrows(PSQLException.class, () -> update(
                    connection, "DELETE FROM production_plan_items WHERE plan_id=?",
                    fixture.planId()));
            assertEquals("55000", deleteFailure.getSQLState());
        }
    }

    @Test
    void partialSubmissionAtomicallyExchangesSoftAllocationForFormalClaim()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = fixture(connection, new BigDecimal("10.0000"),
                    new BigDecimal("4.0000"));
            UUID materialId = UUID.randomUUID();
            insert(connection, """
                    INSERT INTO production_material_analysis_materials(
                        id,analysis_id,analysis_item_id,node_key,goods_id,unit_id,
                        depth,path,per_product_qty,required_qty,available_qty,
                        allocated_available_qty,shortage_qty,source_suggestion
                    ) VALUES(?,?,?,?,?,?,1,?,1,10,10,10,0,'BUY')
                    """, materialId, fixture.analysisId(), fixture.itemId(),
                    "node-" + materialId, fixture.goodsId(), fixture.unitId(),
                    "node-" + materialId);
            UUID linkId = UUID.randomUUID();

            insert(connection, """
                    INSERT INTO production_material_analysis_plan_links(
                        id,analysis_id,analysis_item_id,plan_id,
                        submitted_qty,allocation_status,created_by
                    ) VALUES(?,?,?,?,4,'SUBMITTED',?)
                    """, linkId, fixture.analysisId(), fixture.itemId(),
                    fixture.planId(), fixture.userId());

            assertMaterialQuantities(connection, materialId, "6.0000", "6.0000");
            assertEquals(0, scalarDecimal(connection, """
                    SELECT material.allocated_available_qty
                           + item.submitted_qty + item.approved_qty
                    FROM production_material_analysis_materials material
                    JOIN production_material_analysis_items item
                      ON item.id=material.analysis_item_id
                    WHERE material.id=?
                    """, materialId).compareTo(new BigDecimal("10.0000")));

            update(connection, "UPDATE production_plans SET status=-1 WHERE id=?",
                    fixture.planId());

            assertQuantities(connection, fixture.itemId(), "0.0000", "0.0000");
            assertMaterialQuantities(connection, materialId, "6.0000", "0.0000");
            assertText(connection, """
                    SELECT allocation_status
                    FROM production_material_analysis_plan_links WHERE id=?
                    """, linkId, "REVERSED");
        }
    }

    private static Fixture fixture(Connection connection, BigDecimal requestedQty)
            throws Exception {
        return fixture(connection, requestedQty, requestedQty);
    }

    private static Fixture fixture(
            Connection connection, BigDecimal requestedQty, BigDecimal planQty)
            throws Exception {
        return fixture(connection, requestedQty, planQty, "REQ-" + UUID.randomUUID());
    }

    private static Fixture fixture(
            Connection connection, BigDecimal requestedQty, BigDecimal planQty,
            String sourceRef) throws Exception {
        UUID departmentId = scalarUuid(connection, """
                SELECT id FROM departments WHERE is_deleted=FALSE ORDER BY code LIMIT 1
                """);
        UUID employeeId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID analysisId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();

        insert(connection, """
                INSERT INTO employees(
                    id,code,full_name,id_type,department_id,hire_date,status,employment_type
                ) VALUES(?,?,?,'其他',?,?,'active','regular')
                """, employeeId, "V234-E-" + employeeId, "V234 owner",
                departmentId, LocalDate.of(2026, 1, 1));
        insert(connection, """
                INSERT INTO users(id,employee_id,login_account,password_hash,status)
                VALUES(?,?,?,?,'active')
                """, userId, employeeId, "v234-" + userId, "test-only-hash");
        insert(connection, "INSERT INTO warehouses(id,code,name) VALUES(?,?,?)",
                warehouseId, "V234-W-" + warehouseId, "V234 warehouse");
        insert(connection, "INSERT INTO units(id,code,name) VALUES(?,?,?)",
                unitId, "V234-U-" + unitId, "piece");
        insert(connection, "INSERT INTO goods(id,code,name,unit_id) VALUES(?,?,?,?)",
                goodsId, "V234-G-" + goodsId, "V234 product", unitId);
        insert(connection, """
                INSERT INTO production_material_analyses(
                    id,warehouse_id,status,fingerprint,initial_idempotency_key,maker_id,
                    created_by,updated_by
                ) VALUES(?,?,'ACTIVE',?,?,?, ?,?)
                """, analysisId, warehouseId, "a".repeat(64),
                "initial-" + analysisId, employeeId, userId, userId);
        insert(connection, """
                INSERT INTO production_material_analysis_items(
                    id,analysis_id,source_type,goods_id,unit_id,source_ref,source_reason,
                    requested_qty,line_priority,created_by,updated_by
                ) VALUES(?,?,'OTHER',?,?,?,?, ?,1,?,?)
                """, itemId, analysisId, goodsId, unitId, sourceRef, "DB conservation test",
                requestedQty, userId, userId);
        insert(connection, """
                INSERT INTO production_plans(
                    id,bill_no,bill_date,status,maker_id,created_by,updated_by
                ) VALUES(?,?,?,0,?,?,?)
                """, planId, "V234-P-" + planId, LocalDate.of(2026, 8, 8),
                employeeId, userId, userId);
        insert(connection, """
                INSERT INTO production_plan_items(
                    id,bill_no,bill_date,plan_id,line_no,product_no,
                    goods_id,unit_id,unit_rate,qty,created_by,updated_by
                ) VALUES(?,?,?,?,1,?,?,?,1,?,?,?)
                """, UUID.randomUUID(), "V234-P-" + planId,
                LocalDate.of(2026, 8, 8), planId, "V234-PI-" + planId,
                goodsId, unitId, planQty, userId, userId);
        update(connection, """
                UPDATE production_plans
                SET material_analysis_id=?, material_analysis_item_id=?
                WHERE id=?
                """, analysisId, itemId, planId);
        return new Fixture(analysisId, itemId, planId, userId,
                warehouseId, goodsId, unitId);
    }

    private static void insertAction(
            Connection connection, Fixture fixture, UUID actionId, String qty) throws Exception {
        insert(connection, """
                INSERT INTO preplan_supply_actions(
                    id,analysis_id,warehouse_id,goods_id,unit_id,route,requested_qty,
                    status,idempotency_key,action_group_key,request_business_key,
                    generation,request_hash,created_by
                ) VALUES(?,?,?,?,?,'BUY',?,'OPEN',?,?,?,1,?,?)
                """, actionId, fixture.analysisId(), fixture.warehouseId(),
                fixture.goodsId(), fixture.unitId(), new BigDecimal(qty),
                "idem-" + actionId,
                actionId.toString().replace("-", "").repeat(2),
                actionId.toString().replace("-", "").repeat(2),
                "d".repeat(64), fixture.userId());
    }

    private static void insertAllocation(
            Connection connection, Fixture fixture, UUID materialId,
            UUID actionId, String qty) throws Exception {
        insert(connection, """
                INSERT INTO preplan_supply_action_allocations(
                    id,analysis_id,action_id,analysis_material_id,allocated_qty,created_by
                ) VALUES(?,?,?,?,?,?)
                """, UUID.randomUUID(), fixture.analysisId(), actionId,
                materialId, new BigDecimal(qty), fixture.userId());
    }

    private static void assertQuantities(
            Connection connection, UUID itemId, String submitted, String approved)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                SELECT submitted_qty,approved_qty
                FROM production_material_analysis_items WHERE id=?
                """)) {
            statement.setObject(1, itemId);
            try (ResultSet rows = statement.executeQuery()) {
                rows.next();
                assertEquals(0, rows.getBigDecimal(1).compareTo(new BigDecimal(submitted)));
                assertEquals(0, rows.getBigDecimal(2).compareTo(new BigDecimal(approved)));
            }
        }
    }

    private static void assertReady(
            Connection connection, UUID itemId, String readyNow, String readyBy)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                SELECT ready_now_qty,ready_by_date_qty
                FROM production_material_analysis_items WHERE id=?
                """)) {
            statement.setObject(1, itemId);
            try (ResultSet rows = statement.executeQuery()) {
                rows.next();
                assertEquals(0, rows.getBigDecimal(1).compareTo(new BigDecimal(readyNow)));
                assertEquals(0, rows.getBigDecimal(2).compareTo(new BigDecimal(readyBy)));
            }
        }
    }

    private static void assertMaterialQuantities(
            Connection connection, UUID materialId, String required, String allocated)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("""
                SELECT required_qty,allocated_available_qty
                FROM production_material_analysis_materials WHERE id=?
                """)) {
            statement.setObject(1, materialId);
            try (ResultSet rows = statement.executeQuery()) {
                rows.next();
                assertEquals(0, rows.getBigDecimal(1).compareTo(new BigDecimal(required)));
                assertEquals(0, rows.getBigDecimal(2).compareTo(new BigDecimal(allocated)));
            }
        }
    }

    private static String scalarText(Connection connection, String sql, UUID id)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            try (ResultSet rows = statement.executeQuery()) {
                rows.next();
                return rows.getString(1);
            }
        }
    }

    private static long scalarLong(Connection connection, String sql, UUID id)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            try (ResultSet rows = statement.executeQuery()) {
                rows.next();
                return rows.getLong(1);
            }
        }
    }

    private static BigDecimal scalarDecimal(Connection connection, String sql, UUID id)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            try (ResultSet rows = statement.executeQuery()) {
                rows.next();
                return rows.getBigDecimal(1);
            }
        }
    }

    private static void assertText(
            Connection connection, String sql, UUID id, String expected) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            try (ResultSet rows = statement.executeQuery()) {
                rows.next();
                assertEquals(expected, rows.getString(1));
            }
        }
    }

    private static UUID scalarUuid(Connection connection, String sql) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql);
             ResultSet rows = statement.executeQuery()) {
            rows.next();
            return rows.getObject(1, UUID.class);
        }
    }

    private static int update(Connection connection, String sql, Object... values)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            bind(statement, values);
            return statement.executeUpdate();
        }
    }

    private static void insert(Connection connection, String sql, Object... values)
            throws Exception {
        update(connection, sql, values);
    }

    private static void bind(PreparedStatement statement, Object... values) throws Exception {
        for (int index = 0; index < values.length; index++) {
            statement.setObject(index + 1, values[index]);
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private record Fixture(
            UUID analysisId, UUID itemId, UUID planId, UUID userId,
            UUID warehouseId, UUID goodsId, UUID unitId) {
    }
}
