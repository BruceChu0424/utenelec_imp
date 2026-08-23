package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.PreparedStatement;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PreplanMakeEntitlementDelegationMigrationPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp_make_delegate")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    @BeforeAll
    static void migrate() throws Exception {
        POSTGRES.start();
        flyway("329").migrate();
        migrateOnlyV337();
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void schemaInstallsHeaderStateViewAndStandardAudit() throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            try (ResultSet result = statement.executeQuery("""
                    SELECT to_regclass(
                               'public.preplan_make_entitlement_delegations')
                               IS NOT NULL,
                           to_regclass(
                               'public.v_preplan_make_entitlement_delegation_state')
                               IS NOT NULL
                    """)) {
                assertTrue(result.next());
                assertTrue(result.getBoolean(1));
                assertTrue(result.getBoolean(2));
            }
            try (ResultSet result = statement.executeQuery("""
                    SELECT count(*)
                    FROM pg_trigger trigger_row
                    JOIN pg_proc trigger_function
                      ON trigger_function.oid = trigger_row.tgfoid
                    WHERE trigger_row.tgrelid = to_regclass(
                        'public.preplan_make_entitlement_delegations')
                      AND NOT trigger_row.tgisinternal
                      AND trigger_row.tgname =
                          'trg_audit_preplan_make_entitlement_delegations'
                      AND trigger_function.proname = 'fn_audit'
                    """)) {
                assertTrue(result.next());
                assertEquals(1, result.getInt(1));
            }
        }
    }

    @Test
    void installedBalanceAndGuardRecognizeMakeDelegationPair()
            throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            try (ResultSet result = statement.executeQuery("""
                    SELECT pg_get_viewdef(
                        'v_preplan_stock_entitlement_lot_balance'::regclass,
                        true)
                    """)) {
                assertTrue(result.next());
                String definition = result.getString(1).toLowerCase();
                assertTrue(definition.contains("'make_delegate_out'"));
                assertTrue(definition.contains("'make_delegate_in'"));
            }
            try (ResultSet result = statement.executeQuery("""
                    SELECT pg_get_functiondef(procedure_row.oid)
                    FROM pg_proc procedure_row
                    JOIN pg_namespace namespace_row
                      ON namespace_row.oid = procedure_row.pronamespace
                    WHERE namespace_row.nspname = 'public'
                      AND procedure_row.proname =
                          'fn_check_preplan_stock_entitlement_event'
                    """)) {
                assertTrue(result.next());
                String definition = result.getString(1).toLowerCase();
                assertTrue(definition.contains(
                        "new.event_type = 'make_delegate_out'"));
                assertTrue(definition.contains(
                        "new.event_type = 'make_delegate_in'"));
            }
        }
    }

    @Test
    void makePairMovesCurrentBeneficiaryAndConservesTheExactLot()
            throws Exception {
        Fixture fixture;
        UUID delegationId = UUID.randomUUID();
        UUID outEventId = UUID.randomUUID();
        try (Connection connection = connection()) {
            fixture = createDelegationFixture(connection);
            setActor(connection, fixture.userId());
            connection.setAutoCommit(false);
            execute(connection, """
                    INSERT INTO preplan_make_entitlement_delegations (
                        id, analysis_id, supply_action_id,
                        parent_analysis_material_id, child_analysis_item_id,
                        source_analysis_material_id, target_analysis_material_id,
                        stock_reservation_id, source_entitlement_event_id,
                        qty, idempotency_key, created_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 4, ?, ?)
                    """, delegationId, fixture.analysisId(), fixture.actionId(),
                    fixture.parentMaterialId(), fixture.childItemId(),
                    fixture.sourceMaterialId(), fixture.targetMaterialId(),
                    fixture.reservationId(), fixture.originEventId(),
                    "V337-DELEGATION-" + delegationId, fixture.userId());
            execute(connection, """
                    INSERT INTO preplan_stock_entitlement_events (
                        id, event_group_id, stock_reservation_id,
                        beneficiary_analysis_id,
                        beneficiary_analysis_material_id,
                        event_type, qty, source_entitlement_event_id,
                        idempotency_key, created_by)
                    VALUES (?, ?, ?, ?, ?, 'MAKE_DELEGATE_OUT', 4, ?, ?, ?)
                    """, outEventId, delegationId, fixture.reservationId(),
                    fixture.analysisId(), fixture.sourceMaterialId(),
                    fixture.originEventId(), "V337-OUT-" + delegationId,
                    fixture.userId());
            execute(connection, """
                    INSERT INTO preplan_stock_entitlement_events (
                        event_group_id, stock_reservation_id,
                        beneficiary_analysis_id,
                        beneficiary_analysis_material_id,
                        event_type, qty, source_exact_peg_id,
                        counter_event_id, idempotency_key, created_by)
                    VALUES (?, ?, ?, ?, 'MAKE_DELEGATE_IN', 4, ?, ?, ?, ?)
                    """, delegationId, fixture.reservationId(),
                    fixture.analysisId(), fixture.targetMaterialId(),
                    fixture.exactPegId(), outEventId,
                    "V337-IN-" + delegationId, fixture.userId());
            connection.commit();
        }

        try (Connection connection = connection()) {
            assertDecimal(connection, """
                    SELECT COALESCE((
                        SELECT effective_qty
                        FROM v_preplan_stock_entitlement_beneficiary_balance
                        WHERE stock_reservation_id = ?
                          AND beneficiary_analysis_material_id = ?), 0)
                    """, fixture.reservationId(), fixture.sourceMaterialId(),
                    "6.0000");
            assertDecimal(connection, """
                    SELECT COALESCE((
                        SELECT effective_qty
                        FROM v_preplan_stock_entitlement_beneficiary_balance
                        WHERE stock_reservation_id = ?
                          AND beneficiary_analysis_material_id = ?), 0)
                    """, fixture.reservationId(), fixture.targetMaterialId(),
                    "4.0000");
            assertDecimal(connection, """
                    SELECT SUM(effective_qty)
                    FROM v_preplan_stock_entitlement_beneficiary_balance
                    WHERE stock_reservation_id = ?
                    """, fixture.reservationId(), "10.0000");
            try (PreparedStatement query = connection.prepareStatement("""
                    SELECT state
                    FROM v_preplan_make_entitlement_delegation_state
                    WHERE id = ?
                    """)) {
                query.setObject(1, delegationId);
                try (ResultSet row = query.executeQuery()) {
                    assertTrue(row.next());
                    assertEquals("ACTIVE", row.getString(1));
                }
            }
        }

        try (Connection connection = connection()) {
            SQLException appendOnly = assertThrows(
                    SQLException.class,
                    () -> execute(connection, """
                            UPDATE preplan_make_entitlement_delegations
                            SET qty = 3
                            WHERE id = ?
                            """, delegationId));
            assertEquals("55000", appendOnly.getSQLState());
        }
    }

    private static Fixture createDelegationFixture(Connection connection)
            throws Exception {
        UUID departmentId = scalarUuid(connection, """
                SELECT id FROM departments
                WHERE is_deleted = FALSE
                ORDER BY code
                LIMIT 1
                """);
        UUID employeeId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID parentGoodsId = UUID.randomUUID();
        UUID componentGoodsId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID analysisId = UUID.randomUUID();
        UUID parentItemId = UUID.randomUUID();
        UUID childItemId = UUID.randomUUID();
        UUID parentMaterialId = UUID.randomUUID();
        UUID sourceMaterialId = UUID.randomUUID();
        UUID targetMaterialId = UUID.randomUUID();
        UUID actionId = UUID.randomUUID();
        UUID allocationId = UUID.randomUUID();
        UUID reservationId = UUID.randomUUID();
        UUID exactPegId = UUID.randomUUID();
        UUID originEventId = UUID.randomUUID();
        UUID stockDocumentId = UUID.randomUUID();
        UUID stockDocumentItemId = UUID.randomUUID();
        UUID supplyId = UUID.randomUUID();

        try (Statement statement = connection.createStatement()) {
            statement.execute("SET session_replication_role = replica");
        }
        try {
            execute(connection, """
                    INSERT INTO employees (
                        id, code, full_name, id_type, department_id,
                        hire_date, status, employment_type)
                    VALUES (?, ?, 'V337 migration actor', '其他', ?,
                        DATE '2026-08-22', 'active', 'regular')
                    """, employeeId, "V337-E-" + employeeId, departmentId);
            execute(connection, """
                    INSERT INTO users (
                        id, employee_id, login_account, password_hash, status)
                    VALUES (?, ?, ?, 'test-only-not-a-real-password', 'active')
                    """, userId, employeeId, "v337-" + userId);
            execute(connection, """
                    INSERT INTO units(id, code, name)
                    VALUES (?, ?, 'V337 unit')
                    """, unitId, "V337-U-" + unitId);
            execute(connection, """
                    INSERT INTO goods(id, code, name, unit_id, code_sequence)
                    VALUES (?, ?, 'V337 parent goods', ?,
                        (SELECT COALESCE(max(code_sequence), 0) + 1 FROM goods))
                    """, parentGoodsId, "V337-P-" + parentGoodsId, unitId);
            execute(connection, """
                    INSERT INTO goods(id, code, name, unit_id, code_sequence)
                    VALUES (?, ?, 'V337 component goods', ?,
                        (SELECT COALESCE(max(code_sequence), 0) + 1 FROM goods))
                    """, componentGoodsId, "V337-C-" + componentGoodsId, unitId);
            execute(connection, """
                    INSERT INTO warehouses(id, code, name, status)
                    VALUES (?, ?, 'V337 warehouse', '使用')
                    """, warehouseId, "V337-W-" + warehouseId);
            execute(connection, """
                    INSERT INTO production_material_analyses (
                        id, warehouse_id, status, fingerprint,
                        initial_idempotency_key, maker_id, created_by, updated_by)
                    VALUES (?, ?, 'ACTIVE', ?, ?, ?, ?, ?)
                    """, analysisId, warehouseId, "a".repeat(64),
                    "V337-ANALYSIS-" + analysisId, employeeId, userId, userId);
            execute(connection, """
                    INSERT INTO production_material_analysis_items (
                        id, analysis_id, source_type, goods_id, unit_id,
                        source_ref, source_reason, requested_qty, line_priority,
                        created_by, updated_by)
                    VALUES (?, ?, 'OTHER', ?, ?, ?, 'V337 parent product', 1, 1, ?, ?)
                    """, parentItemId, analysisId, parentGoodsId, unitId,
                    "V337-PARENT-" + parentItemId, userId, userId);
            insertMaterial(connection, parentMaterialId, analysisId, parentItemId,
                    "PARENT", null, parentGoodsId, unitId, 1, 1,
                    "MAKE", "MAKE", userId);
            execute(connection, """
                    INSERT INTO production_material_analysis_items (
                        id, analysis_id, source_type, goods_id, unit_id,
                        source_ref, source_reason, requested_qty, line_priority,
                        parent_analysis_material_id, created_by, updated_by)
                    VALUES (?, ?, 'MAKE_COMPONENT', ?, ?, ?,
                        'V337 delegated child', 1, 2, ?, ?, ?)
                    """, childItemId, analysisId, parentGoodsId, unitId,
                    "V337-CHILD-" + childItemId, parentMaterialId, userId, userId);
            insertMaterial(connection, sourceMaterialId, analysisId, parentItemId,
                    "PARENT/SOURCE", "PARENT", componentGoodsId, unitId, 2, 10,
                    "BUY", "BUY", userId);
            insertMaterial(connection, targetMaterialId, analysisId, childItemId,
                    "SOURCE", null, componentGoodsId, unitId, 1, 10,
                    "BUY", "BUY", userId);
            execute(connection, """
                    INSERT INTO preplan_supply_actions (
                        id, analysis_id, warehouse_id, goods_id, unit_id,
                        route, requested_qty, status, external_document_type,
                        external_document_id, idempotency_key, action_group_key,
                        request_business_key, request_hash, created_by)
                    VALUES (?, ?, ?, ?, ?, 'MAKE', 1, 'CREATED',
                        'PREPLAN_MAKE_TASK', ?, ?, ?, ?, ?, ?)
                    """, actionId, analysisId, warehouseId, parentGoodsId, unitId,
                    childItemId, "V337-ACTION-" + actionId, "b".repeat(64),
                    "c".repeat(64), "d".repeat(64), userId);
            execute(connection, """
                    INSERT INTO preplan_supply_action_allocations (
                        id, analysis_id, action_id, analysis_material_id,
                        allocated_qty, external_item_id, created_by)
                    VALUES (?, ?, ?, ?, 1, ?, ?)
                    """, allocationId, analysisId, actionId, parentMaterialId,
                    childItemId, userId);
            execute(connection, """
                    INSERT INTO stock_documents (
                        id, doc_type, bill_no, bill_date, warehouse_id, status)
                    VALUES (?, 'FINISHED_IN', ?, DATE '2026-08-22', ?, 1)
                    """, stockDocumentId, "CR20260822990001", warehouseId);
            execute(connection, """
                    INSERT INTO stock_document_items (
                        id, doc_id, bill_type, bill_no, bill_date, line_no,
                        goods_id, unit_id, qty, base_qty, unit_rate,
                        goods_snapshot_source)
                    VALUES (?, ?, 'FINISHED_IN', ?, DATE '2026-08-22', 1,
                        ?, ?, 10, 10, 1, 'MASTER_AT_SAVE')
                    """, stockDocumentItemId, stockDocumentId,
                    "CR20260822990001", componentGoodsId, unitId);
            execute(connection, """
                    INSERT INTO stock_reservations (
                        id, goods_id, warehouse_id, qty, source,
                        source_doc_type, source_doc_id, owner_type, owner_id,
                        purpose, supply_type, supply_id, idempotency_key,
                        created_by, updated_by)
                    VALUES (?, ?, ?, 10, 1, 'PRODUCTION_INBOUND', ?,
                        'PREPLAN_ANALYSIS', ?, 'PREPLAN_MATERIAL',
                        'PRODUCTION_PLAN_ITEM', ?, ?, ?, ?)
                    """, reservationId, componentGoodsId, warehouseId,
                    stockDocumentId, analysisId, supplyId,
                    "V337-RESERVATION-" + reservationId, userId, userId);
            execute(connection, """
                    INSERT INTO preplan_analysis_stock_exact_pegs (
                        id, stock_reservation_id, supply_action_allocation_id,
                        origin_analysis_id, origin_analysis_material_id,
                        beneficiary_analysis_id,
                        beneficiary_analysis_material_id, qty,
                        source_receipt_type, source_receipt_id,
                        source_disposition_event_id,
                        source_stock_document_id,
                        source_stock_document_item_id,
                        beneficiary_reason, idempotency_key,
                        created_by, updated_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 10, 'MAKE', ?, NULL, ?, ?,
                        'ORIGIN_MAKE', ?, ?, ?)
                    """, exactPegId, reservationId, allocationId, analysisId,
                    sourceMaterialId, analysisId, sourceMaterialId,
                    stockDocumentId, stockDocumentId, stockDocumentItemId,
                    "V337-EXACT-" + exactPegId, userId, userId);
            execute(connection, """
                    INSERT INTO preplan_stock_entitlement_events (
                        id, event_group_id, stock_reservation_id,
                        beneficiary_analysis_id,
                        beneficiary_analysis_material_id,
                        event_type, qty, source_exact_peg_id,
                        source_receipt_type, source_receipt_id,
                        source_stock_document_id,
                        source_stock_document_item_id,
                        idempotency_key, created_by)
                    VALUES (?, ?, ?, ?, ?, 'ORIGIN_MAKE', 10, ?,
                        'MAKE', ?, ?, ?, ?, ?)
                    """, originEventId, UUID.randomUUID(), reservationId,
                    analysisId, sourceMaterialId, exactPegId,
                    stockDocumentId, stockDocumentId, stockDocumentItemId,
                    "V337-ORIGIN-" + originEventId, userId);
        } finally {
            try (Statement statement = connection.createStatement()) {
                statement.execute("SET session_replication_role = origin");
            }
        }
        return new Fixture(
                userId, analysisId, childItemId, parentMaterialId,
                sourceMaterialId, targetMaterialId, actionId, reservationId,
                exactPegId, originEventId);
    }

    private static void insertMaterial(
            Connection connection, UUID id, UUID analysisId, UUID itemId,
            String nodeKey, String parentNodeKey, UUID goodsId, UUID unitId,
            int depth, int requiredQty, String suggestion,
            String confirmedRoute, UUID userId) throws Exception {
        execute(connection, """
                INSERT INTO production_material_analysis_materials (
                    id, analysis_id, analysis_item_id, node_key,
                    parent_node_key, goods_id, unit_id, depth, path,
                    per_product_qty, required_qty, available_qty,
                    allocated_available_qty, shortage_qty, source_suggestion,
                    confirmed_route, route_confirmed_by, route_confirmed_at,
                    created_by, updated_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, 0, 0, ?,
                    ?, ?, ?, now(), ?, ?)
                """, id, analysisId, itemId, nodeKey, parentNodeKey,
                goodsId, unitId, depth, nodeKey, requiredQty, requiredQty,
                suggestion, confirmedRoute, userId, userId, userId);
    }

    private static int execute(
            Connection connection, String sql, Object... values)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < values.length; index++) {
                statement.setObject(index + 1, values[index]);
            }
            return statement.executeUpdate();
        }
    }

    private static UUID scalarUuid(
            Connection connection, String sql, Object... values)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < values.length; index++) {
                statement.setObject(index + 1, values[index]);
            }
            try (ResultSet row = statement.executeQuery()) {
                assertTrue(row.next());
                return row.getObject(1, UUID.class);
            }
        }
    }

    private static void assertDecimal(
            Connection connection, String sql, UUID first, String expected)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, first);
            try (ResultSet row = statement.executeQuery()) {
                assertTrue(row.next());
                assertEquals(0, row.getBigDecimal(1)
                        .compareTo(new BigDecimal(expected)));
            }
        }
    }

    private static void assertDecimal(
            Connection connection, String sql, UUID first, UUID second,
            String expected) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, first);
            statement.setObject(2, second);
            try (ResultSet row = statement.executeQuery()) {
                assertTrue(row.next());
                assertEquals(0, row.getBigDecimal(1)
                        .compareTo(new BigDecimal(expected)));
            }
        }
    }

    private static void setActor(Connection connection, UUID actorId)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(
                "SELECT set_config('app.actor_id', ?, false)")) {
            statement.setString(1, actorId.toString());
            try (ResultSet row = statement.executeQuery()) {
                assertTrue(row.next());
            }
        }
    }

    private record Fixture(
            UUID userId,
            UUID analysisId,
            UUID childItemId,
            UUID parentMaterialId,
            UUID sourceMaterialId,
            UUID targetMaterialId,
            UUID actionId,
            UUID reservationId,
            UUID exactPegId,
            UUID originEventId) {
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private static Flyway flyway(String target) {
        return Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .validateMigrationNaming(true)
                .target(target)
                .load();
    }

    private static void migrateOnlyV337() throws Exception {
        Path directory = Files.createTempDirectory("uten-v337-only-");
        Path migration = directory.resolve(
                "V337__preplan_make_entitlement_delegation.sql");
        try {
            Files.copy(
                    Path.of("src/main/resources/db/migration/"
                            + "V337__preplan_make_entitlement_delegation.sql"),
                    migration,
                    StandardCopyOption.REPLACE_EXISTING);
            Flyway.configure()
                    .dataSource(
                            POSTGRES.getJdbcUrl(),
                            POSTGRES.getUsername(),
                            POSTGRES.getPassword())
                    .locations("filesystem:" + directory.toAbsolutePath())
                    .validateOnMigrate(false)
                    .target("337")
                    .load()
                    .migrate();
        } finally {
            Files.deleteIfExists(migration);
            Files.deleteIfExists(directory);
        }
    }
}
