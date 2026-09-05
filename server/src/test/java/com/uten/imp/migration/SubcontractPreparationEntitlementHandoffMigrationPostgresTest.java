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
import java.sql.Statement;
import java.math.BigDecimal;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractPreparationEntitlementHandoffMigrationPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp_v447_handoff")
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
    void emptyDatabaseAppliesV447WithAuditedAppendOnlyConservationGuards()
            throws Exception {
        try (Connection connection = connection();
             Statement statement = connection.createStatement()) {
            assertThat(scalar(statement, """
                    SELECT COUNT(*) FROM flyway_schema_history
                    WHERE version = '447' AND success
                    """)).isEqualTo(1);
            assertThat(scalar(statement, """
                    SELECT COUNT(*) FROM information_schema.tables
                    WHERE table_schema = 'public'
                      AND table_name IN (
                        'preplan_subcontract_requirement_handoffs',
                        'preplan_subcontract_requirement_handoff_items',
                        'preplan_subcontract_requirement_supply_claims',
                        'preplan_subcontract_entitlement_handoff_slices',
                        'preplan_subcontract_requirement_handoff_events')
                    """)).isEqualTo(5);
            assertThat(scalar(statement, """
                    SELECT COUNT(*) FROM information_schema.views
                    WHERE table_schema = 'public'
                      AND table_name IN (
                        'v_preplan_subcontract_requirement_handoff_state',
                        'v_preplan_subcontract_parent_output_claim_balance',
                        'v_preplan_subcontract_requirement_supply_claim_state',
                        'v_preplan_subcontract_target_future_supply',
                        'v_preplan_subcontract_entitlement_handoff_slice_state')
                    """)).isEqualTo(5);
            assertThat(scalar(statement, """
                    SELECT COUNT(*)
                    FROM pg_trigger trigger_row
                    JOIN pg_proc trigger_function
                      ON trigger_function.oid = trigger_row.tgfoid
                    WHERE trigger_row.tgrelid IN (
                        'preplan_subcontract_requirement_handoffs'::regclass,
                        'preplan_subcontract_requirement_handoff_items'::regclass,
                        'preplan_subcontract_requirement_supply_claims'::regclass,
                        'preplan_subcontract_entitlement_handoff_slices'::regclass,
                        'preplan_subcontract_requirement_handoff_events'::regclass)
                      AND NOT trigger_row.tgisinternal
                      AND trigger_row.tgenabled <> 'D'
                      AND trigger_function.proname IN (
                          'fn_audit',
                          'fn_guard_preplan_subcontract_handoff_mutation')
                    """)).isEqualTo(10);
            assertThat(scalar(statement, """
                    SELECT COUNT(*)
                    FROM pg_trigger
                    WHERE NOT tgisinternal AND tgenabled <> 'D'
                      AND tgname IN (
                        'trg_check_preplan_subcontract_requirement_handoff',
                        'trg_subcontract_preparation_handoff_required',
                        'trg_validate_preplan_subcontract_requirement_header',
                        'trg_validate_preplan_subcontract_requirement_events',
                        'trg_validate_preplan_subcontract_supply_claim_rows',
                        'trg_validate_preplan_subcontract_handoff_slice',
                        'trg_validate_preplan_subcontract_handoff_events')
                    """)).isEqualTo(7);
            assertThat(scalar(statement, """
                    SELECT COUNT(*)
                    FROM pg_indexes
                    WHERE schemaname = 'public'
                      AND indexname IN (
                        'uq_preplan_subcontract_handoff_out_group',
                        'uq_preplan_subcontract_handoff_in_group',
                        'uq_preplan_subcontract_handoff_in_counter')
                    """)).isEqualTo(3);
        }
    }

    @Test
    void exactHandoffMovesTheBeneficiaryAndLegacyReleaseRestoreAcceptsTheNewLot()
            throws Exception {
        HandoffFixture fixture;
        UUID outEventId = UUID.randomUUID();
        UUID inEventId = UUID.randomUUID();
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            fixture = seedHandoffFixture(connection);
            setActor(connection, fixture.userId());
            execute(connection, """
                    INSERT INTO preplan_stock_entitlement_events(
                        id,event_group_id,stock_reservation_id,
                        beneficiary_analysis_id,beneficiary_analysis_material_id,
                        event_type,qty,source_entitlement_event_id,
                        idempotency_key,created_by)
                    VALUES (?,?,?,?,?,'SUBCONTRACT_HANDOFF_OUT',4,?,?,?)
                    """, outEventId, fixture.sliceId(), fixture.reservationId(),
                    fixture.sourceAnalysisId(), fixture.sourceMaterialId(),
                    fixture.originEventId(), "V447-OUT-" + fixture.sliceId(),
                    fixture.userId());
            execute(connection, """
                    INSERT INTO preplan_stock_entitlement_events(
                        id,event_group_id,stock_reservation_id,
                        beneficiary_analysis_id,beneficiary_analysis_material_id,
                        event_type,qty,source_exact_peg_id,counter_event_id,
                        idempotency_key,created_by)
                    VALUES (?,?,?,?,?,'SUBCONTRACT_HANDOFF_IN',4,?,?,?,?)
                    """, inEventId, fixture.sliceId(), fixture.reservationId(),
                    fixture.targetAnalysisId(), fixture.targetMaterialId(),
                    fixture.exactPegId(), outEventId,
                    "V447-IN-" + fixture.sliceId(), fixture.userId());
            connection.commit();
        }

        try (Connection connection = connection()) {
            assertDecimal(connection, """
                    SELECT COALESCE((SELECT effective_qty
                        FROM v_preplan_stock_entitlement_beneficiary_balance
                        WHERE stock_reservation_id=?
                          AND beneficiary_analysis_material_id=?),0)
                    """, fixture.reservationId(), fixture.sourceMaterialId(), "6");
            assertDecimal(connection, """
                    SELECT COALESCE((SELECT effective_qty
                        FROM v_preplan_stock_entitlement_beneficiary_balance
                        WHERE stock_reservation_id=?
                          AND beneficiary_analysis_material_id=?),0)
                    """, fixture.reservationId(), fixture.targetMaterialId(), "4");
        }

        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            setActor(connection, fixture.userId());
            execute(connection, """
                    INSERT INTO preplan_stock_entitlement_events(
                        event_group_id,stock_reservation_id,
                        beneficiary_analysis_id,beneficiary_analysis_material_id,
                        event_type,qty,source_entitlement_event_id,
                        idempotency_key,created_by)
                    VALUES (?,?,?,?, 'RELEASE',4,?,?,?)
                    """, fixture.sliceId(), fixture.reservationId(),
                    fixture.targetAnalysisId(), fixture.targetMaterialId(), inEventId,
                    "V447-RELEASE-" + fixture.sliceId(), fixture.userId());
            execute(connection, """
                    INSERT INTO preplan_stock_entitlement_events(
                        event_group_id,stock_reservation_id,
                        beneficiary_analysis_id,beneficiary_analysis_material_id,
                        event_type,qty,source_exact_peg_id,counter_event_id,
                        idempotency_key,created_by)
                    VALUES (?,?,?,?, 'RESTORE',4,?,?,?,?)
                    """, fixture.sliceId(), fixture.reservationId(),
                    fixture.sourceAnalysisId(), fixture.sourceMaterialId(),
                    fixture.exactPegId(), outEventId,
                    "V447-STOCK-RESTORE-" + fixture.sliceId(), fixture.userId());
            execute(connection, """
                    INSERT INTO preplan_subcontract_requirement_handoff_events(
                        handoff_id,event_type,qty,counter_event_id,reason,
                        idempotency_key,created_by)
                    VALUES (?,'RESTORE',4,?,'test restores parent requirement',?,?)
                    """, fixture.handoffId(), fixture.takeoverEventId(),
                    "V447-REQ-RESTORE-" + fixture.handoffId(), fixture.userId());
            connection.commit();
        }

        try (Connection connection = connection()) {
            assertDecimal(connection, """
                    SELECT COALESCE((SELECT effective_qty
                        FROM v_preplan_stock_entitlement_beneficiary_balance
                        WHERE stock_reservation_id=?
                          AND beneficiary_analysis_material_id=?),0)
                    """, fixture.reservationId(), fixture.sourceMaterialId(), "10");
            assertDecimal(connection, """
                    SELECT COALESCE((SELECT effective_qty
                        FROM v_preplan_stock_entitlement_beneficiary_balance
                        WHERE stock_reservation_id=?
                          AND beneficiary_analysis_material_id=?),0)
                    """, fixture.reservationId(), fixture.targetMaterialId(), "0");
            assertThat(text(connection, """
                    SELECT state
                    FROM v_preplan_subcontract_entitlement_handoff_slice_state
                    WHERE id=?
                    """, fixture.sliceId())).isEqualTo("RESTORED");
        }
    }

    private static HandoffFixture seedHandoffFixture(Connection connection)
            throws Exception {
        UUID userId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID sourceAnalysisId = UUID.randomUUID();
        UUID targetAnalysisId = UUID.randomUUID();
        UUID sourceItemId = UUID.randomUUID();
        UUID targetItemId = UUID.randomUUID();
        UUID sourceMaterialId = UUID.randomUUID();
        UUID targetMaterialId = UUID.randomUUID();
        UUID actionId = UUID.randomUUID();
        UUID allocationId = UUID.randomUUID();
        UUID reservationId = UUID.randomUUID();
        UUID exactPegId = UUID.randomUUID();
        UUID originEventId = UUID.randomUUID();
        UUID handoffId = UUID.randomUUID();
        UUID mappedItemId = UUID.randomUUID();
        UUID sliceId = UUID.randomUUID();
        UUID takeoverEventId = UUID.randomUUID();
        UUID bomItemId = UUID.randomUUID();
        UUID sourceDocumentId = UUID.randomUUID();
        UUID sourceDocumentItemId = UUID.randomUUID();
        String analysisFingerprint = "a".repeat(64);
        String sourceAnalysisKey = "V447-A-" + sourceAnalysisId;
        String targetAnalysisKey = "V447-A-" + targetAnalysisId;
        try (Statement statement = connection.createStatement()) {
            statement.execute("SET LOCAL session_replication_role = replica");
        }
        execute(connection, """
                INSERT INTO employees(
                    id,code,full_name,id_type,department_id,hire_date,
                    status,employment_type)
                VALUES (?,?,?,'其他',?,DATE '2026-08-31','active','regular')
                """, employeeId, "V447-E-" + employeeId,
                "V447 migration actor", UUID.randomUUID());
        execute(connection, """
                INSERT INTO users(id,employee_id,login_account,password_hash,status)
                VALUES (?,?,?, 'test-only-not-a-real-password','active')
                """, userId, employeeId, "v447-" + userId);
        execute(connection, "INSERT INTO units(id,code,name) VALUES (?,?,?)",
                unitId, "V447-U-" + unitId, "V447 unit");
        execute(connection, """
                INSERT INTO goods(id,code,name,unit_id,code_sequence)
                VALUES (?,?,?, ?, (SELECT COALESCE(max(code_sequence),0)+1 FROM goods))
                """, goodsId, "V447-G-" + goodsId, "V447 component", unitId);
        execute(connection, """
                INSERT INTO warehouses(id,code,name,status)
                VALUES (?,?,?,'使用')
                """, warehouseId, "V447-W-" + warehouseId, "V447 warehouse");
        for (UUID analysisId : new UUID[]{sourceAnalysisId, targetAnalysisId}) {
            execute(connection, """
                    INSERT INTO production_material_analyses(
                        id,warehouse_id,status,fingerprint,initial_idempotency_key,
                        maker_id,created_by,updated_by,participating_warehouse_ids)
                    SELECT v.id, v.wid, 'ACTIVE', v.fp, v.k, v.maker, v.cb, v.ub,
                           ARRAY[v.wid]::UUID[]
                    FROM (VALUES (?::uuid,?::uuid,repeat('a',64),?::text,?::uuid,?::uuid,?::uuid))
                         AS v(id,wid,fp,k,maker,cb,ub)
                    """, analysisId, warehouseId, "V447-A-" + analysisId,
                    UUID.randomUUID(), userId, userId);
        }
        execute(connection, """
                INSERT INTO production_material_analysis_items(
                    id,analysis_id,source_type,goods_id,unit_id,source_ref,
                    source_reason,requested_qty,line_priority,created_by,updated_by)
                VALUES (?,?, 'OTHER',?,?,?,'source analysis',10,1,?,?),
                       (?,?, 'SUBCONTRACT_PREPARATION',?,?,?,
                        'target preparation',10,1,?,?)
                """, sourceItemId, sourceAnalysisId, goodsId, unitId,
                "V447-SOURCE-" + sourceItemId, userId, userId,
                targetItemId, targetAnalysisId, goodsId, unitId,
                "SC-PREP:" + UUID.randomUUID(), userId, userId);
        insertMaterial(connection, sourceMaterialId, sourceAnalysisId,
                sourceItemId, goodsId, unitId, bomItemId, userId);
        insertMaterial(connection, targetMaterialId, targetAnalysisId,
                targetItemId, goodsId, unitId, bomItemId, userId);
        execute(connection, """
                INSERT INTO preplan_supply_actions(
                    id,analysis_id,warehouse_id,goods_id,unit_id,need_date,
                    route,requested_qty,status,external_document_type,
                    external_document_id,idempotency_key,action_group_key,
                    request_business_key,request_hash,created_by)
                VALUES (?,?,?,?,?,DATE '2026-09-01','MAKE',10,'CREATED',
                    'PREPLAN_MAKE_TASK',?,?,?,?,?,?)
                """, actionId, sourceAnalysisId, warehouseId, goodsId, unitId,
                UUID.randomUUID(), "V447-ACTION-" + actionId, "b".repeat(64),
                "c".repeat(64), "d".repeat(64), userId);
        execute(connection, """
                INSERT INTO preplan_supply_action_allocations(
                    id,analysis_id,action_id,analysis_material_id,
                    allocated_qty,external_item_id,created_by)
                VALUES (?,?,?,?,10,?,?)
                """, allocationId, sourceAnalysisId, actionId,
                sourceMaterialId, UUID.randomUUID(), userId);
        execute(connection, """
                INSERT INTO stock_reservations(
                    id,goods_id,warehouse_id,qty,source,source_doc_type,
                    source_doc_id,owner_type,owner_id,purpose,supply_type,
                    supply_id,idempotency_key,created_by,updated_by)
                VALUES (?,?,?,10,1,'PRODUCTION_INBOUND',?,
                    'PREPLAN_ANALYSIS',?,'PREPLAN_MATERIAL',
                    'PRODUCTION_PLAN_ITEM',?,?,?,?)
                """, reservationId, goodsId, warehouseId, sourceDocumentId,
                sourceAnalysisId, UUID.randomUUID(),
                "V447-RES-" + reservationId, userId, userId);
        execute(connection, """
                INSERT INTO preplan_analysis_stock_exact_pegs(
                    id,stock_reservation_id,supply_action_allocation_id,
                    origin_analysis_id,origin_analysis_material_id,
                    beneficiary_analysis_id,beneficiary_analysis_material_id,
                    qty,source_receipt_type,source_receipt_id,
                    source_disposition_event_id,source_stock_document_id,
                    source_stock_document_item_id,beneficiary_reason,
                    idempotency_key,created_by,updated_by)
                VALUES (?,?,?,?,?,?,?,10,'MAKE',?,NULL,?,?,'ORIGIN_MAKE',?,?,?)
                """, exactPegId, reservationId, allocationId,
                sourceAnalysisId, sourceMaterialId, sourceAnalysisId,
                sourceMaterialId, sourceDocumentId, sourceDocumentId,
                sourceDocumentItemId, "V447-EXACT-" + exactPegId, userId, userId);
        execute(connection, """
                INSERT INTO preplan_stock_entitlement_events(
                    id,event_group_id,stock_reservation_id,
                    beneficiary_analysis_id,beneficiary_analysis_material_id,
                    event_type,qty,source_exact_peg_id,source_receipt_type,
                    source_receipt_id,source_stock_document_id,
                    source_stock_document_item_id,idempotency_key,created_by)
                VALUES (?,?,?,?,?,'ORIGIN_MAKE',10,?,'MAKE',?,?,?,?,?)
                """, originEventId, UUID.randomUUID(), reservationId,
                sourceAnalysisId, sourceMaterialId, exactPegId,
                sourceDocumentId, sourceDocumentId, sourceDocumentItemId,
                "V447-ORIGIN-" + originEventId, userId);
        execute(connection, """
                INSERT INTO preplan_subcontract_requirement_handoffs(
                    id,plan_item_id,source_supply_action_id,
                    source_supply_action_allocation_id,source_analysis_id,
                    source_analysis_item_id,source_parent_material_id,
                    target_analysis_id,target_analysis_item_id,warehouse_id,
                    target_goods_id,target_unit_id,parent_output_qty,
                    source_analysis_version,source_analysis_fingerprint,
                    target_analysis_version,target_analysis_fingerprint,
                    idempotency_key,request_hash,created_by)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,4,0,repeat('a',64),0,
                    repeat('a',64),?,repeat('f',64),?)
                """, handoffId, UUID.randomUUID(), actionId, allocationId,
                sourceAnalysisId, sourceItemId, sourceMaterialId,
                targetAnalysisId, targetItemId, warehouseId, goodsId, unitId,
                "V447-HANDOFF-" + handoffId, userId);
        execute(connection, """
                INSERT INTO preplan_subcontract_requirement_handoff_items(
                    id,handoff_id,position,source_analysis_id,
                    source_analysis_material_id,target_analysis_id,
                    target_analysis_material_id,relative_bom_path,bom_item_id,
                    goods_id,unit_id,source_required_qty_snapshot,
                    target_required_qty_snapshot,transfer_capacity_qty,
                    idempotency_key,created_by)
                VALUES (?,?,1,?,?,?,?,ARRAY[?]::uuid[],?,?,?,10,4,4,?,?)
                """, mappedItemId, handoffId, sourceAnalysisId,
                sourceMaterialId, targetAnalysisId, targetMaterialId,
                bomItemId, bomItemId, goodsId, unitId,
                "V447-MAP-" + mappedItemId, userId);
        execute(connection, """
                INSERT INTO preplan_subcontract_entitlement_handoff_slices(
                    id,handoff_item_id,stock_reservation_id,
                    source_entitlement_event_id,source_exact_peg_id,qty,
                    idempotency_key,created_by)
                VALUES (?,?,?,?,?,4,?,?)
                """, sliceId, mappedItemId, reservationId, originEventId,
                exactPegId, "V447-SLICE-" + sliceId, userId);
        execute(connection, """
                INSERT INTO preplan_subcontract_requirement_handoff_events(
                    id,handoff_id,event_type,qty,reason,idempotency_key,created_by)
                VALUES (?,?,'TAKEOVER',4,'test takes parent requirement',?,?)
                """, takeoverEventId, handoffId,
                "V447-TAKEOVER-" + handoffId, userId);
        try (Statement statement = connection.createStatement()) {
            statement.execute("SET LOCAL session_replication_role = origin");
        }
        return new HandoffFixture(userId, sourceAnalysisId, targetAnalysisId,
                sourceMaterialId, targetMaterialId, reservationId, exactPegId,
                originEventId, handoffId, sliceId, takeoverEventId);
    }

    private static void insertMaterial(
            Connection connection, UUID id, UUID analysisId, UUID itemId,
            UUID goodsId, UUID unitId, UUID bomItemId, UUID userId)
            throws Exception {
        execute(connection, """
                INSERT INTO production_material_analysis_materials(
                    id,analysis_id,analysis_item_id,node_key,bom_item_id,
                    goods_id,unit_id,depth,path,per_product_qty,required_qty,
                    available_qty,allocated_available_qty,shortage_qty,
                    source_suggestion,created_by,updated_by)
                VALUES (?,?,?,?,?,?,?,1,?,1,10,0,0,10,'BUY',?,?)
                """, id, analysisId, itemId, "NODE-" + id, bomItemId,
                goodsId, unitId, "NODE-" + id, userId, userId);
    }

    private static int execute(Connection connection, String sql, Object... values)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < values.length; index++) {
                statement.setObject(index + 1, values[index]);
            }
            return statement.executeUpdate();
        }
    }

    private static void setActor(Connection connection, UUID actorId)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(
                "SELECT set_config('app.actor_id', ?, true)")) {
            statement.setString(1, actorId.toString());
            statement.executeQuery().close();
        }
    }

    private static void assertDecimal(
            Connection connection, String sql, UUID first, UUID second,
            String expected) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, first);
            statement.setObject(2, second);
            try (ResultSet row = statement.executeQuery()) {
                assertThat(row.next()).isTrue();
                assertThat(row.getBigDecimal(1))
                        .isEqualByComparingTo(new BigDecimal(expected));
            }
        }
    }

    private static String text(Connection connection, String sql, UUID id)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            try (ResultSet row = statement.executeQuery()) {
                assertThat(row.next()).isTrue();
                return row.getString(1);
            }
        }
    }

    private record HandoffFixture(
            UUID userId, UUID sourceAnalysisId, UUID targetAnalysisId,
            UUID sourceMaterialId, UUID targetMaterialId,
            UUID reservationId, UUID exactPegId, UUID originEventId,
            UUID handoffId, UUID sliceId, UUID takeoverEventId) {
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private static long scalar(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getLong(1);
        }
    }
}
