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
        UUID departmentId = UUID.randomUUID();
        UUID productId = UUID.randomUUID();
        UUID outerProductId = UUID.randomUUID();
        UUID parentBomItemId = UUID.randomUUID();
        UUID parentMaterialId = UUID.randomUUID();
        UUID makeTaskItemId = UUID.randomUUID();
        UUID makePlanId = UUID.randomUUID();
        UUID makePlanItemId = UUID.randomUUID();
        UUID subcontractActionId = UUID.randomUUID();
        UUID subcontractAllocationId = UUID.randomUUID();
        UUID applicationId = UUID.randomUUID();
        UUID applicationItemId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID supplierId = UUID.randomUUID();
        UUID settlementId = UUID.randomUUID();
        String analysisFingerprint = "a".repeat(64);
        String sourceAnalysisKey = "V447-A-" + sourceAnalysisId;
        String targetAnalysisKey = "V447-A-" + targetAnalysisId;
        try (Statement statement = connection.createStatement()) {
            // Import the pre-existing source lot and old SC-PREP task. Every new
            // V447 handoff fact below is written after restoring ordinary guards.
            statement.execute("SET LOCAL session_replication_role = replica");
        }
        execute(connection,"INSERT INTO departments(id,code,name,level) VALUES(?,?,?,'一级部门')",departmentId,"V447-D-"+departmentId,"V447 source department");
        execute(connection, """
                INSERT INTO employees(
                    id,code,full_name,id_type,department_id,hire_date,
                    status,employment_type)
                VALUES (?,?,?,'其他',?,DATE '2026-08-31','active','regular')
                """, employeeId, "V447-E-" + employeeId,
                "V447 migration actor", departmentId);
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
        execute(connection,"""
                INSERT INTO goods(id,code,name,unit_id,code_sequence)
                VALUES(?,?,?, ?, (SELECT COALESCE(max(code_sequence),0)+1 FROM goods))
                """,productId,"V447-P-"+productId,"V447 subcontract target",unitId);
        execute(connection,"INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty) VALUES(?,?,?,1)",bomItemId,productId,goodsId);
        execute(connection,"""
                INSERT INTO goods(id,code,name,unit_id,code_sequence)
                VALUES(?,?,?, ?, (SELECT COALESCE(max(code_sequence),0)+1 FROM goods))
                """,outerProductId,"V447-O-"+outerProductId,"V447 outer assembly",unitId);
        execute(connection,"INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty) VALUES(?,?,?,1)",parentBomItemId,outerProductId,productId);
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
                    employeeId, userId, userId);
        }
        execute(connection, """
                INSERT INTO production_material_analysis_items(
                    id,analysis_id,source_type,goods_id,unit_id,source_ref,
                    source_reason,requested_qty,line_priority,created_by,updated_by)
                VALUES (?,?, 'OTHER',?,?,?,'source analysis',10,1,?,?),
                       (?,?, 'SUBCONTRACT_PREPARATION',?,?,?,
                        'target preparation',4,1,?,?)
                """, sourceItemId, sourceAnalysisId, outerProductId, unitId,
                "V447-SOURCE-" + sourceItemId, userId, userId,
                targetItemId, targetAnalysisId, productId, unitId,
                "SC-PREP:" + orderItemId, userId, userId);
        execute(connection,"""
                INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,bom_item_id,
                    goods_id,unit_id,depth,path,per_product_qty,required_qty,available_qty,allocated_available_qty,shortage_qty,
                    source_suggestion,created_by,updated_by)
                VALUES(?,?,?,?,?,?,?,1,?,1,10,0,0,10,'SUBCONTRACT',?,?)
                """,parentMaterialId,sourceAnalysisId,sourceItemId,parentBomItemId.toString(),parentBomItemId,productId,unitId,parentBomItemId.toString(),userId,userId);
        insertMaterial(connection, sourceMaterialId, sourceAnalysisId,
                sourceItemId, goodsId, unitId, bomItemId, userId,parentBomItemId+"/"+bomItemId,"10");
        insertMaterial(connection, targetMaterialId, targetAnalysisId,
                targetItemId, goodsId, unitId, bomItemId, userId,bomItemId.toString(),"4");
        execute(connection,"""
                INSERT INTO production_material_analysis_items(id,analysis_id,source_type,goods_id,unit_id,source_ref,
                    source_reason,requested_qty,line_priority,parent_analysis_material_id,created_by,updated_by)
                VALUES(?,?,'MAKE_COMPONENT',?,?,?,'historical component manufacture',10,2,?,?,?)
                """,makeTaskItemId,sourceAnalysisId,goodsId,unitId,"V447-MAKE-"+makeTaskItemId,sourceMaterialId,userId,userId);
        execute(connection, """
                INSERT INTO preplan_supply_actions(
                    id,analysis_id,warehouse_id,goods_id,unit_id,need_date,
                    route,requested_qty,status,external_document_type,
                    external_document_id,idempotency_key,action_group_key,
                    request_business_key,request_hash,created_by)
                VALUES (?,?,?,?,?,DATE '2026-09-01','MAKE',10,'CREATED',
                    'PREPLAN_MAKE_TASK',?,?,?,?,?,?)
                """, actionId, sourceAnalysisId, warehouseId, goodsId, unitId,
                makeTaskItemId, "V447-ACTION-" + actionId, "b".repeat(64),
                "c".repeat(64), "d".repeat(64), userId);
        execute(connection, """
                INSERT INTO preplan_supply_action_allocations(
                    id,analysis_id,action_id,analysis_material_id,
                    allocated_qty,external_item_id,created_by)
                VALUES (?,?,?,?,10,?,?)
                """, allocationId, sourceAnalysisId, actionId,
                sourceMaterialId, makeTaskItemId, userId);
        execute(connection,"""
                INSERT INTO production_plans(id,bill_no,bill_date,status) VALUES(?,'SJ20260831000001',DATE '2026-08-31',1)
                """,makePlanId);
        execute(connection,"""
                INSERT INTO production_plan_items(id,plan_id,bill_no,bill_date,product_no,goods_id,unit_id,unit_rate,qty,fqty,iqty)
                VALUES(?,?,'SJ20260831000001',DATE '2026-08-31',?,?,?,1,10,10,10)
                """,makePlanItemId,makePlanId,"V447-MAKE-"+makePlanItemId,goodsId,unitId);
        execute(connection,"""
                INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,warehouse_id,status)
                VALUES(?,'FINISHED_IN','CR20260831000001',DATE '2026-08-31',?,1)
                """,sourceDocumentId,warehouseId);
        execute(connection,"""
                INSERT INTO stock_document_items(id,doc_id,bill_type,bill_no,bill_date,line_no,goods_id,unit_id,unit_rate,qty,base_qty,upstream_item_id,goods_snapshot_source)
                VALUES(?,?,'FINISHED_IN','CR20260831000001',DATE '2026-08-31',1,?,?,1,10,10,?,'MASTER_AT_SAVE')
                """,sourceDocumentItemId,sourceDocumentId,goodsId,unitId,makePlanItemId);
        execute(connection,"INSERT INTO stock_balances(id,warehouse_id,goods_id,qty) VALUES(?,?,?,10)",UUID.randomUUID(),warehouseId,goodsId);
        execute(connection, """
                INSERT INTO stock_reservations(
                    id,goods_id,warehouse_id,qty,source,source_doc_type,
                    source_doc_id,owner_type,owner_id,purpose,supply_type,
                    supply_id,idempotency_key,created_by,updated_by)
                VALUES (?,?,?,10,1,'PRODUCTION_INBOUND',?,
                    'PREPLAN_ANALYSIS',?,'PREPLAN_MATERIAL',
                    'PRODUCTION_PLAN_ITEM',?,?,?,?)
                """, reservationId, goodsId, warehouseId, sourceDocumentId,
                sourceAnalysisId, makePlanItemId,
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
        execute(connection,"""
                INSERT INTO suppliers(id,code,name,code_sequence,category_id) VALUES(?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM suppliers),
                    (SELECT id FROM supplier_categories WHERE legacy_id=-1))
                """,supplierId,"V447-S-"+supplierId,"V447 subcontractor");
        execute(connection,"INSERT INTO settlement_methods(id,code,name,status) VALUES(?,?,?,'使用')",settlementId,"V447-T-"+settlementId,"V447 settlement");
        execute(connection,"""
                INSERT INTO subcontract_applications(id,bill_no,bill_date,supplier_id,warehouse_id,status,maker_id,created_by,updated_by)
                VALUES(?,'EB20260831000001',DATE '2026-08-31',?,?,1,?,?,?)
                """,applicationId,supplierId,warehouseId,employeeId,userId,userId);
        execute(connection,"""
                INSERT INTO subcontract_application_items(id,bill_no,bill_date,application_id,line_no,goods_id,unit_id,unit_rate,qty,ordered_qty,
                    goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                VALUES(?,'EB20260831000001',DATE '2026-08-31',?,1,?,?,1,4,4,?,'V447 subcontract target','MASTER_AT_APPROVAL',now())
                """,applicationItemId,applicationId,productId,unitId,"V447-P-"+productId);
        execute(connection,"""
                INSERT INTO subcontract_orders(id,bill_no,bill_date,supplier_id,warehouse_id,settlement_method_id,status,maker_id,created_by,updated_by)
                VALUES(?,'EO20260831000001',DATE '2026-08-31',?,?,?,1,?,?,?)
                """,orderId,supplierId,warehouseId,settlementId,employeeId,userId,userId);
        execute(connection,"""
                INSERT INTO subcontract_order_items(id,bill_no,bill_date,order_id,application_item_id,line_no,goods_id,unit_id,unit_rate,qty,
                    goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                VALUES(?,'EO20260831000001',DATE '2026-08-31',?,?,1,?,?,1,4,?,'V447 subcontract target','MASTER_AT_APPROVAL',now())
                """,orderItemId,orderId,applicationItemId,productId,unitId,"V447-P-"+productId);
        execute(connection,"""
                INSERT INTO preplan_supply_actions(id,analysis_id,warehouse_id,goods_id,unit_id,need_date,route,requested_qty,status,
                    external_document_type,external_document_id,idempotency_key,action_group_key,request_business_key,request_hash,created_by)
                VALUES(?,?,?,?,?,DATE '2026-09-01','SUBCONTRACT',4,'CREATED','SUBCONTRACT_APPLICATION',?,?,?,?,?,?)
                """,subcontractActionId,sourceAnalysisId,warehouseId,productId,unitId,applicationId,"V447-SC-ACTION-"+subcontractActionId,
                "e".repeat(64),"f".repeat(64),"a".repeat(64),userId);
        execute(connection,"""
                INSERT INTO preplan_supply_action_allocations(id,analysis_id,action_id,analysis_material_id,allocated_qty,external_item_id,created_by)
                VALUES(?,?,?,?,4,?,?)
                """,subcontractAllocationId,sourceAnalysisId,subcontractActionId,parentMaterialId,applicationItemId,userId);
        execute(connection,"""
                INSERT INTO subcontract_material_plans(id,order_id,order_bill_no,supplier_id,status,created_by,updated_by)
                VALUES(?,?,'EO20260831000001',?,'OPEN',?,?)
                """,planId,orderId,supplierId,userId,userId);
        execute(connection,"""
                INSERT INTO subcontract_material_plan_items(id,plan_id,order_item_id,line_no,parent_goods_id,goods_id,unit_id,unit_rate,bom_unit_qty,
                    planned_qty,issued_qty,flow_mode,preparation_status,prepared_qty,bom_has_children_snapshot,preparation_bom_fingerprint,
                    preparation_warehouse_id,created_by,updated_by)
                VALUES(?,?,?,1,?,?,?,1,1,4,0,'MAKE_THEN_OUTBOUND','ACTION_REQUIRED',0,TRUE,repeat('a',64),?,?,?)
                """,planItemId,planId,orderItemId,productId,productId,unitId,warehouseId,userId,userId);
        try (Statement statement = connection.createStatement()) {
            statement.execute("SET LOCAL session_replication_role = origin");
        }
        setActor(connection,userId);
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
                """, handoffId, planItemId, subcontractActionId, subcontractAllocationId,
                sourceAnalysisId, sourceItemId, parentMaterialId,
                targetAnalysisId, targetItemId, warehouseId, productId, unitId,
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
        execute(connection,"""
                UPDATE subcontract_material_plan_items SET preparation_status='IN_PREPARATION',preparation_analysis_id=?,
                    preparation_analysis_item_id=?,preparation_started_by=?,preparation_started_at=now(),updated_by=?,updated_at=now()
                WHERE id=? AND preparation_status='ACTION_REQUIRED'
                """,targetAnalysisId,targetItemId,userId,userId,planItemId);
        try(var statement=connection.prepareStatement("SELECT fn_assert_subcontract_preparation_source(?),fn_assert_preplan_subcontract_requirement_handoff(?)")){
            statement.setObject(1,planItemId);statement.setObject(2,handoffId);statement.executeQuery().close();
        }
        return new HandoffFixture(userId, sourceAnalysisId, targetAnalysisId,
                sourceMaterialId, targetMaterialId, reservationId, exactPegId,
                originEventId, handoffId, sliceId, takeoverEventId);
    }

    private static void insertMaterial(
            Connection connection, UUID id, UUID analysisId, UUID itemId,
            UUID goodsId, UUID unitId, UUID bomItemId, UUID userId,String nodeKey,String quantity)
            throws Exception {
        execute(connection, """
                INSERT INTO production_material_analysis_materials(
                    id,analysis_id,analysis_item_id,node_key,parent_node_key,bom_item_id,
                    goods_id,unit_id,depth,path,per_product_qty,required_qty,
                    available_qty,allocated_available_qty,shortage_qty,
                    source_suggestion,created_by,updated_by)
                VALUES (?,?,?,?,?,?,?,?,?,?,1,?,0,0,?,'MAKE',?,?)
                """, id, analysisId, itemId, nodeKey,nodeKey.contains("/")?nodeKey.substring(0,nodeKey.lastIndexOf('/')):null,bomItemId,
                goodsId, unitId,nodeKey.contains("/")?2:1,nodeKey,new BigDecimal(quantity),new BigDecimal(quantity), userId, userId);
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
