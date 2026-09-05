package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * V467 行为锁定：V337 的委托头触发器在 b0a62cd1（notify 循环放开 SUBCONTRACT
 * 迁移 exact 权益）后仍写死 MAKE 形状，真库「下达委外」被
 * 23514「invalid preplan MAKE entitlement delegation」整体回滚（2026-09-04
 * 事故）。源码文本断言测不到 DB 触发器，本测试在干净库 V1→head 上分别以
 * MAKE 与 SUBCONTRACT 形状插入委托对，并验证配对不匹配仍失败关闭。
 * （SQL 一律调用点内联单行字面量 + ? 绑定，符合 Mimosa 门禁配方：
 * prepareStatement 的 SQL 参数为变量/文本块均拦截。）
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractMakeDelegationRouteGuardPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp_subcontract_delegate")
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
                .validateMigrationNaming(true)
                .load()
                .migrate();
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void subcontractPairInsertsAndMovesExactLot() throws Exception {
        Fixture fixture;
        UUID delegationId = UUID.randomUUID();
        UUID outEventId = UUID.randomUUID();
        String delegationKey = String.format("V467-DELEGATION-%s", delegationId);
        String outKey = String.format("V467-OUT-%s", delegationId);
        String inKey = String.format("V467-IN-%s", delegationId);
        try (Connection connection = connection()) {
            fixture = createFixture(connection, RouteShape.SUBCONTRACT);
            setActor(connection, fixture.userId());
            connection.setAutoCommit(false);
            insertDelegation(connection, delegationId, fixture, 4, delegationKey);
            insertOutEvent(connection, outEventId, delegationId, fixture, 4, outKey);
            insertInEvent(connection, delegationId, outEventId, fixture, 4, inKey);
            connection.commit();
        }

        try (Connection connection = connection()) {
            assertBalance(connection, fixture.reservationId(),
                    fixture.sourceMaterialId(), "6.0000");
            assertBalance(connection, fixture.reservationId(),
                    fixture.targetMaterialId(), "4.0000");
            assertTotalBalance(connection, fixture.reservationId(), "10.0000");
            assertEquals("ACTIVE", delegationState(connection, delegationId));
        }
    }

    @Test
    void makePairStillInsertsAfterRouteCase() throws Exception {
        Fixture fixture;
        UUID delegationId = UUID.randomUUID();
        UUID outEventId = UUID.randomUUID();
        String delegationKey = String.format("V467-DELEGATION-%s", delegationId);
        String outKey = String.format("V467-OUT-%s", delegationId);
        String inKey = String.format("V467-IN-%s", delegationId);
        try (Connection connection = connection()) {
            fixture = createFixture(connection, RouteShape.MAKE);
            setActor(connection, fixture.userId());
            connection.setAutoCommit(false);
            insertDelegation(connection, delegationId, fixture, 3, delegationKey);
            insertOutEvent(connection, outEventId, delegationId, fixture, 3, outKey);
            insertInEvent(connection, delegationId, outEventId, fixture, 3, inKey);
            connection.commit();
        }

        try (Connection connection = connection()) {
            assertBalance(connection, fixture.reservationId(),
                    fixture.targetMaterialId(), "3.0000");
        }
    }

    @Test
    void routeShapeMismatchStaysFailClosed() throws Exception {
        Fixture fixture;
        UUID delegationId = UUID.randomUUID();
        String delegationKey = String.format("V467-DELEGATION-%s", delegationId);
        try (Connection connection = connection()) {
            fixture = createFixture(connection, RouteShape.MISMATCHED);
            setActor(connection, fixture.userId());
            connection.setAutoCommit(false);
            SQLException rejected = assertThrows(SQLException.class,
                    () -> insertDelegation(
                            connection, delegationId, fixture, 4, delegationKey));
            assertEquals("23514", rejected.getSQLState());
            connection.rollback();
        }
    }

    private enum RouteShape {
        MAKE, SUBCONTRACT, MISMATCHED
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

    private static void insertDelegation(
            Connection connection, UUID delegationId, Fixture fixture, int qty,
            String idempotencyKey) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(
                "INSERT INTO preplan_make_entitlement_delegations(id, analysis_id, supply_action_id, parent_analysis_material_id, child_analysis_item_id, source_analysis_material_id, target_analysis_material_id, stock_reservation_id, source_entitlement_event_id, qty, idempotency_key, created_by) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)")) {
            statement.setObject(1, delegationId);
            statement.setObject(2, fixture.analysisId());
            statement.setObject(3, fixture.actionId());
            statement.setObject(4, fixture.parentMaterialId());
            statement.setObject(5, fixture.childItemId());
            statement.setObject(6, fixture.sourceMaterialId());
            statement.setObject(7, fixture.targetMaterialId());
            statement.setObject(8, fixture.reservationId());
            statement.setObject(9, fixture.originEventId());
            statement.setInt(10, qty);
            statement.setString(11, idempotencyKey);
            statement.setObject(12, fixture.userId());
            statement.executeUpdate();
        }
    }

    private static void insertOutEvent(
            Connection connection, UUID outEventId, UUID delegationId,
            Fixture fixture, int qty, String idempotencyKey) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(
                "INSERT INTO preplan_stock_entitlement_events(id, event_group_id, stock_reservation_id, beneficiary_analysis_id, beneficiary_analysis_material_id, event_type, qty, source_entitlement_event_id, idempotency_key, created_by) VALUES (?,?,?,?,?,'MAKE_DELEGATE_OUT',?,?,?,?)")) {
            statement.setObject(1, outEventId);
            statement.setObject(2, delegationId);
            statement.setObject(3, fixture.reservationId());
            statement.setObject(4, fixture.analysisId());
            statement.setObject(5, fixture.sourceMaterialId());
            statement.setInt(6, qty);
            statement.setObject(7, fixture.originEventId());
            statement.setString(8, idempotencyKey);
            statement.setObject(9, fixture.userId());
            statement.executeUpdate();
        }
    }

    private static void insertInEvent(
            Connection connection, UUID delegationId, UUID outEventId,
            Fixture fixture, int qty, String idempotencyKey) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(
                "INSERT INTO preplan_stock_entitlement_events(event_group_id, stock_reservation_id, beneficiary_analysis_id, beneficiary_analysis_material_id, event_type, qty, source_exact_peg_id, counter_event_id, idempotency_key, created_by) VALUES (?,?,?,?,'MAKE_DELEGATE_IN',?,?,?,?,?)")) {
            statement.setObject(1, delegationId);
            statement.setObject(2, fixture.reservationId());
            statement.setObject(3, fixture.analysisId());
            statement.setObject(4, fixture.targetMaterialId());
            statement.setInt(5, qty);
            statement.setObject(6, fixture.exactPegId());
            statement.setObject(7, outEventId);
            statement.setString(8, idempotencyKey);
            statement.setObject(9, fixture.userId());
            statement.executeUpdate();
        }
    }

    private static String delegationState(
            Connection connection, UUID delegationId) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(
                "SELECT state FROM v_preplan_make_entitlement_delegation_state WHERE id=?")) {
            statement.setObject(1, delegationId);
            try (ResultSet row = statement.executeQuery()) {
                assertTrue(row.next());
                return row.getString(1);
            }
        }
    }

    private static void assertBalance(
            Connection connection, UUID reservationId, UUID materialId,
            String expected) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(
                "SELECT COALESCE((SELECT effective_qty FROM v_preplan_stock_entitlement_beneficiary_balance WHERE stock_reservation_id=? AND beneficiary_analysis_material_id=?),0)")) {
            statement.setObject(1, reservationId);
            statement.setObject(2, materialId);
            try (ResultSet row = statement.executeQuery()) {
                assertTrue(row.next());
                assertEquals(0, row.getBigDecimal(1)
                        .compareTo(new BigDecimal(expected)));
            }
        }
    }

    private static void assertTotalBalance(
            Connection connection, UUID reservationId, String expected)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(
                "SELECT COALESCE(SUM(effective_qty),0) FROM v_preplan_stock_entitlement_beneficiary_balance WHERE stock_reservation_id=?")) {
            statement.setObject(1, reservationId);
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

    private static void insertMaterial(
            Connection connection, UUID id, UUID analysisId, UUID itemId,
            String nodeKey, String parentNodeKey, UUID goodsId, UUID unitId,
            int depth, int shortageQty, String suggestion,
            String confirmedRoute, String routeReason, UUID userId)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(
                "INSERT INTO production_material_analysis_materials(id, analysis_id, analysis_item_id, node_key, parent_node_key, goods_id, unit_id, depth, path, per_product_qty, required_qty, available_qty, allocated_available_qty, shortage_qty, source_suggestion, confirmed_route, route_reason, route_confirmed_by, route_confirmed_at, created_by, updated_by) VALUES (?,?,?,?,?,?,?,?,?,1,?,0,0,?,?,?,?,?,now(),?,?)")) {
            statement.setObject(1, id);
            statement.setObject(2, analysisId);
            statement.setObject(3, itemId);
            statement.setString(4, nodeKey);
            statement.setString(5, parentNodeKey);
            statement.setObject(6, goodsId);
            statement.setObject(7, unitId);
            statement.setInt(8, depth);
            statement.setString(9, nodeKey);
            statement.setInt(10, shortageQty);
            statement.setInt(11, shortageQty);
            statement.setString(12, suggestion);
            statement.setString(13, confirmedRoute);
            statement.setString(14, routeReason);
            statement.setObject(15, userId);
            statement.setObject(16, userId);
            statement.setObject(17, userId);
            statement.executeUpdate();
        }
    }

    private static Fixture createFixture(
            Connection connection, RouteShape shape) throws Exception {
        UUID departmentId = departmentId(connection);
        String tag = String.format("%s-%s",
                shape.name().substring(0, 4),
                UUID.randomUUID().toString().substring(0, 8));
        String employeeCode = String.format("V467-E-%s", tag);
        String loginAccount = String.format("v467-%s", tag);
        String unitCode = String.format("V467-U-%s", tag);
        String parentGoodsCode = String.format("V467-P-%s", tag);
        String componentGoodsCode = String.format("V467-C-%s", tag);
        String warehouseCode = String.format("V467-W-%s", tag);
        String analysisKey = String.format("V467-ANALYSIS-%s", tag);
        String parentRef = String.format("V467-PARENT-%s", tag);
        String childRef = String.format("V467-CHILD-%s", tag);
        String actionKey = String.format("V467-ACTION-%s", tag);
        String reservationKey = String.format("V467-RESERVATION-%s", tag);
        String exactKey = String.format("V467-EXACT-%s", tag);
        String originKey = String.format("V467-ORIGIN-%s", tag);
        String digits = tag.replaceAll("[^0-9]", "");
        String billNo = String.format("CR2026090%s9", digits);
        String fingerprint = "a".repeat(64);
        String actionGroupKey = "b".repeat(64);
        String requestBusinessKey = "c".repeat(64);
        String requestHash = "d".repeat(64);

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

        String parentRoute = shape == RouteShape.MAKE ? "MAKE" : "SUBCONTRACT";
        String childType = shape == RouteShape.MAKE
                ? "MAKE_COMPONENT" : "SUBCONTRACT_MAKE";
        String actionRoute = shape == RouteShape.MISMATCHED
                ? "SUBCONTRACT" : parentRoute;
        String documentType = shape == RouteShape.MAKE
                ? "PREPLAN_MAKE_TASK" : "SUBCONTRACT_MAKE_TASK";
        // MISMATCHED：action/child 是 SUBCONTRACT 形状，但父物料路线仍是 MAKE，
        // 触发器的 parent_material.confirmed_route = action.route 必须拒绝。
        String parentConfirmedRoute = shape == RouteShape.MISMATCHED
                ? "MAKE" : parentRoute;
        String parentRouteReason = shape == RouteShape.MISMATCHED
                ? "测试：确认路线与建议不一致" : null;

        try (Statement statement = connection.createStatement()) {
            statement.execute("SET session_replication_role = replica");
        }
        try {
            try (PreparedStatement statement = connection.prepareStatement(
                    "INSERT INTO employees(id, code, full_name, id_type, department_id, hire_date, status, employment_type) VALUES (?,?,'V467 guard actor','其他',?,DATE '2026-09-04','active','regular')")) {
                statement.setObject(1, employeeId);
                statement.setString(2, employeeCode);
                statement.setObject(3, departmentId);
                statement.executeUpdate();
            }
            try (PreparedStatement statement = connection.prepareStatement(
                    "INSERT INTO users(id, employee_id, login_account, password_hash, status) VALUES (?,?,?,'test-only-not-a-real-password','active')")) {
                statement.setObject(1, userId);
                statement.setObject(2, employeeId);
                statement.setString(3, loginAccount);
                statement.executeUpdate();
            }
            try (PreparedStatement statement = connection.prepareStatement(
                    "INSERT INTO units(id, code, name) VALUES (?,?,'V467 unit')")) {
                statement.setObject(1, unitId);
                statement.setString(2, unitCode);
                statement.executeUpdate();
            }
            try (PreparedStatement statement = connection.prepareStatement(
                    "INSERT INTO goods(id, code, name, unit_id, code_sequence) VALUES (?,?,'V467 parent goods',?,(SELECT COALESCE(max(code_sequence),0)+1 FROM goods))")) {
                statement.setObject(1, parentGoodsId);
                statement.setString(2, parentGoodsCode);
                statement.setObject(3, unitId);
                statement.executeUpdate();
            }
            try (PreparedStatement statement = connection.prepareStatement(
                    "INSERT INTO goods(id, code, name, unit_id, code_sequence) VALUES (?,?,'V467 component goods',?,(SELECT COALESCE(max(code_sequence),0)+1 FROM goods))")) {
                statement.setObject(1, componentGoodsId);
                statement.setString(2, componentGoodsCode);
                statement.setObject(3, unitId);
                statement.executeUpdate();
            }
            try (PreparedStatement statement = connection.prepareStatement(
                    "INSERT INTO warehouses(id, code, name, status) VALUES (?,?,'V467 warehouse','使用')")) {
                statement.setObject(1, warehouseId);
                statement.setString(2, warehouseCode);
                statement.executeUpdate();
            }
            // replica 模式禁用触发器，V471 的 participating 自动回填不会执行，
            // CHECK 约束仍生效——夹具必须显式带上参与仓库集合。
            try (PreparedStatement statement = connection.prepareStatement(
                    "INSERT INTO production_material_analyses(id, warehouse_id, status, fingerprint, initial_idempotency_key, maker_id, created_by, updated_by, participating_warehouse_ids) VALUES (?,?,'ACTIVE',?,?,?,?,?, ARRAY[?]::UUID[])")) {
                statement.setObject(1, analysisId);
                statement.setObject(2, warehouseId);
                statement.setString(3, fingerprint);
                statement.setString(4, analysisKey);
                statement.setObject(5, employeeId);
                statement.setObject(6, userId);
                statement.setObject(7, userId);
                statement.setObject(8, warehouseId);
                statement.executeUpdate();
            }
            try (PreparedStatement statement = connection.prepareStatement(
                    "INSERT INTO production_material_analysis_items(id, analysis_id, source_type, goods_id, unit_id, source_ref, source_reason, requested_qty, line_priority, created_by, updated_by) VALUES (?,?,'OTHER',?,?,?,'V467 parent product',1,1,?,?)")) {
                statement.setObject(1, parentItemId);
                statement.setObject(2, analysisId);
                statement.setObject(3, parentGoodsId);
                statement.setObject(4, unitId);
                statement.setString(5, parentRef);
                statement.setObject(6, userId);
                statement.setObject(7, userId);
                statement.executeUpdate();
            }
            insertMaterial(connection, parentMaterialId, analysisId, parentItemId,
                    "PARENT", null, parentGoodsId, unitId, 1, 1,
                    parentRoute, parentConfirmedRoute, parentRouteReason, userId);
            try (PreparedStatement statement = connection.prepareStatement(
                    "INSERT INTO production_material_analysis_items(id, analysis_id, source_type, goods_id, unit_id, source_ref, source_reason, requested_qty, line_priority, parent_analysis_material_id, created_by, updated_by) VALUES (?,?,?,?,?,?,'V467 delegated child',1,2,?,?,?)")) {
                statement.setObject(1, childItemId);
                statement.setObject(2, analysisId);
                statement.setString(3, childType);
                statement.setObject(4, parentGoodsId);
                statement.setObject(5, unitId);
                statement.setString(6, childRef);
                statement.setObject(7, parentMaterialId);
                statement.setObject(8, userId);
                statement.setObject(9, userId);
                statement.executeUpdate();
            }
            insertMaterial(connection, sourceMaterialId, analysisId, parentItemId,
                    "PARENT/SOURCE", "PARENT", componentGoodsId, unitId, 2, 10,
                    "BUY", "BUY", null, userId);
            insertMaterial(connection, targetMaterialId, analysisId, childItemId,
                    "SOURCE", null, componentGoodsId, unitId, 1, 10,
                    "BUY", "BUY", null, userId);
            try (PreparedStatement statement = connection.prepareStatement(
                    "INSERT INTO preplan_supply_actions(id, analysis_id, warehouse_id, goods_id, unit_id, route, requested_qty, status, external_document_type, external_document_id, idempotency_key, action_group_key, request_business_key, request_hash, created_by) VALUES (?,?,?,?,?,?,1,'CREATED',?,?,?,?,?,?,?)")) {
                statement.setObject(1, actionId);
                statement.setObject(2, analysisId);
                statement.setObject(3, warehouseId);
                statement.setObject(4, parentGoodsId);
                statement.setObject(5, unitId);
                statement.setString(6, actionRoute);
                statement.setString(7, documentType);
                statement.setObject(8, childItemId);
                statement.setString(9, actionKey);
                statement.setString(10, actionGroupKey);
                statement.setString(11, requestBusinessKey);
                statement.setString(12, requestHash);
                statement.setObject(13, userId);
                statement.executeUpdate();
            }
            try (PreparedStatement statement = connection.prepareStatement(
                    "INSERT INTO preplan_supply_action_allocations(id, analysis_id, action_id, analysis_material_id, allocated_qty, external_item_id, created_by) VALUES (?,?,?,?,1,?,?)")) {
                statement.setObject(1, allocationId);
                statement.setObject(2, analysisId);
                statement.setObject(3, actionId);
                statement.setObject(4, parentMaterialId);
                statement.setObject(5, childItemId);
                statement.setObject(6, userId);
                statement.executeUpdate();
            }
            try (PreparedStatement statement = connection.prepareStatement(
                    "INSERT INTO stock_documents(id, doc_type, bill_no, bill_date, warehouse_id, status) VALUES (?,'FINISHED_IN',?,DATE '2026-09-04',?,1)")) {
                statement.setObject(1, stockDocumentId);
                statement.setString(2, billNo);
                statement.setObject(3, warehouseId);
                statement.executeUpdate();
            }
            try (PreparedStatement statement = connection.prepareStatement(
                    "INSERT INTO stock_document_items(id, doc_id, bill_type, bill_no, bill_date, line_no, goods_id, unit_id, qty, base_qty, unit_rate, goods_snapshot_source) VALUES (?,?,'FINISHED_IN',?,DATE '2026-09-04',1,?,?,10,10,1,'MASTER_AT_SAVE')")) {
                statement.setObject(1, stockDocumentItemId);
                statement.setObject(2, stockDocumentId);
                statement.setString(3, billNo);
                statement.setObject(4, componentGoodsId);
                statement.setObject(5, unitId);
                statement.executeUpdate();
            }
            try (PreparedStatement statement = connection.prepareStatement(
                    "INSERT INTO stock_reservations(id, goods_id, warehouse_id, qty, source, source_doc_type, source_doc_id, owner_type, owner_id, purpose, supply_type, supply_id, idempotency_key, created_by, updated_by) VALUES (?,?,?,10,1,'PRODUCTION_INBOUND',?,'PREPLAN_ANALYSIS',?,'PREPLAN_MATERIAL','PRODUCTION_PLAN_ITEM',?,?,?,?)")) {
                statement.setObject(1, reservationId);
                statement.setObject(2, componentGoodsId);
                statement.setObject(3, warehouseId);
                statement.setObject(4, stockDocumentId);
                statement.setObject(5, analysisId);
                statement.setObject(6, supplyId);
                statement.setString(7, reservationKey);
                statement.setObject(8, userId);
                statement.setObject(9, userId);
                statement.executeUpdate();
            }
            try (PreparedStatement statement = connection.prepareStatement(
                    "INSERT INTO preplan_analysis_stock_exact_pegs(id, stock_reservation_id, supply_action_allocation_id, origin_analysis_id, origin_analysis_material_id, beneficiary_analysis_id, beneficiary_analysis_material_id, qty, source_receipt_type, source_receipt_id, source_disposition_event_id, source_stock_document_id, source_stock_document_item_id, beneficiary_reason, idempotency_key, created_by, updated_by) VALUES (?,?,?,?,?,?,?,10,'MAKE',?,NULL,?,?,'ORIGIN_MAKE',?,?,?)")) {
                statement.setObject(1, exactPegId);
                statement.setObject(2, reservationId);
                statement.setObject(3, allocationId);
                statement.setObject(4, analysisId);
                statement.setObject(5, sourceMaterialId);
                statement.setObject(6, analysisId);
                statement.setObject(7, sourceMaterialId);
                statement.setObject(8, stockDocumentId);
                statement.setObject(9, stockDocumentId);
                statement.setObject(10, stockDocumentItemId);
                statement.setString(11, exactKey);
                statement.setObject(12, userId);
                statement.setObject(13, userId);
                statement.executeUpdate();
            }
            try (PreparedStatement statement = connection.prepareStatement(
                    "INSERT INTO preplan_stock_entitlement_events(id, event_group_id, stock_reservation_id, beneficiary_analysis_id, beneficiary_analysis_material_id, event_type, qty, source_exact_peg_id, source_receipt_type, source_receipt_id, source_stock_document_id, source_stock_document_item_id, idempotency_key, created_by) VALUES (?,?,?,?,?,'ORIGIN_MAKE',10,?,'MAKE',?,?,?,?,?)")) {
                statement.setObject(1, originEventId);
                statement.setObject(2, UUID.randomUUID());
                statement.setObject(3, reservationId);
                statement.setObject(4, analysisId);
                statement.setObject(5, sourceMaterialId);
                statement.setObject(6, exactPegId);
                statement.setObject(7, stockDocumentId);
                statement.setObject(8, stockDocumentId);
                statement.setObject(9, stockDocumentItemId);
                statement.setString(10, originKey);
                statement.setObject(11, userId);
                statement.executeUpdate();
            }
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

    private static UUID departmentId(Connection connection) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(
                "SELECT id FROM departments WHERE is_deleted=FALSE ORDER BY code LIMIT 1")) {
            try (ResultSet row = statement.executeQuery()) {
                assertTrue(row.next());
                return row.getObject(1, UUID.class);
            }
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }
}
