package com.uten.imp.migration;

import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.DriverManager;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Populated pre-actual-consumption upgrade: preserve historical estimates and separate new actual consumption. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractActualConsumptionUpgradePostgresTest {
    @Test
    void historicalAllowanceConsumptionRetainsItsExactSlicesAndCannotPayForNewActualReceipts() throws Exception {
        try (var postgres = new PostgreSQLContainer("postgres:16-alpine")
                .withDatabaseName("subcontract_actual_upgrade").withReuse(false)) {
            postgres.start();
            TestFlyway.configure().dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                    .locations("classpath:db/migration").target("1095").load().migrate();
            var db = new JdbcTemplate(new DriverManagerDataSource(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword()));
            UUID order = UUID.randomUUID(), item = UUID.randomUUID(), plan = UUID.randomUUID();
            UUID line = UUID.randomUUID(), issue = UUID.randomUUID(), issueLine = UUID.randomUUID();
            UUID receipt = UUID.randomUUID(), receiptLine = UUID.randomUUID();
            UUID consumption = UUID.randomUUID();
            UUID completedCase=UUID.randomUUID(),acceptedCase=UUID.randomUUID(),openCase=UUID.randomUUID();
            try (var connection = DriverManager.getConnection(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())) {
                connection.setAutoCommit(false);
                var fixture = new SubcontractStepDrawMigrationPostgresTest();
                fixture.db = connection;
                var master = fixture.fixture("loss-upgrade");
                UUID parent = fixture.goods(master, "P", "委外");
                UUID material = fixture.goods(master, "M", "采购");
                fixture.bom(parent, material, "1");
                // Same explicit historical import pattern as the V798 migration matrix.
                // All upgrade DML and assertions run after restoring origin guards.
                try (var statement = connection.createStatement()) {
                    statement.execute("SET LOCAL session_replication_role=replica");
                    try {
                        try (var insert = connection.prepareStatement("""
                                INSERT INTO subcontract_orders(id,bill_no,bill_date,status,settlement_method_id)
                                VALUES (?,'UP-ORDER',current_date,1,
                                    (SELECT id FROM settlement_methods WHERE NOT is_deleted ORDER BY code LIMIT 1));
                                INSERT INTO subcontract_order_items(id,order_id,bill_no,bill_date,goods_id,goods_snapshot_source,
                                    qty,unit_rate,unit_id,line_no,allowed_loss_pct,received_qty)
                                VALUES (?,?,'UP-ORDER',current_date,?,'MASTER_AT_SAVE',100,1,?,1,10,20);
                                INSERT INTO subcontract_material_plans(id,order_id,order_bill_no) VALUES (?,?,'UP-ORDER');
                                INSERT INTO subcontract_material_plan_items(id,plan_id,order_item_id,line_no,parent_goods_id,
                                    goods_id,unit_id,unit_rate,base_bom_unit_qty,material_loss_pct,bom_unit_qty,planned_qty,issued_qty)
                                VALUES (?,?,?,1,?,?,?,1,1,10,1.1,110,40);
                                INSERT INTO subcontract_material_issues(id,bill_no,bill_date,status,warehouse_id)
                                VALUES (?,'UP-ISSUE',current_date,1,?);
                                INSERT INTO subcontract_material_issue_items(id,bill_no,bill_date,issue_id,order_item_id,goods_id,
                                    goods_snapshot_source,unit_id,unit_rate,qty,plan_item_id,requested_qty,at_supplier_qty,
                                    consumed_qty,frozen_unit_qty,parent_goods_id)
                                VALUES (?,'UP-ISSUE',current_date,?,?,?,'MASTER_AT_SAVE',?,1,40,?,40,40,22,1.1,?);
                                INSERT INTO subcontract_receipts(id,bill_no,bill_date,status) VALUES (?,'UP-RECEIPT',current_date,1);
                                INSERT INTO subcontract_receipt_items(id,bill_no,bill_date,receipt_id,order_item_id,goods_id,
                                    goods_snapshot_source,qty,unit_id,unit_rate,material_basis_qty,replacement_intent,
                                    amount_original,amount_local)
                                VALUES (?,'UP-RECEIPT',current_date,?,?,?,'MASTER_AT_SAVE',20,?,1,20,'NORMAL',0,0)
                                """)) {
                            Object[] values = {order,item,order,parent,master.unit(),plan,order,line,plan,item,parent,material,
                                    master.unit(),issue,master.warehouse(),issueLine,issue,item,material,master.unit(),line,parent,
                                    receipt,receiptLine,receipt,item,parent,master.unit()};
                            for (int index=0; index<values.length; index++) insert.setObject(index+1,values[index]);
                            insert.execute();
                        }
                        try (var consideration = connection.prepareStatement("""
                                INSERT INTO procurement_receipt_consideration_parts(
                                    id,receipt_type,receipt_id,receipt_item_id,billing_mode,base_qty,
                                    nominal_original,nominal_local,payable_original,payable_local,created_by)
                                VALUES (?,'SUBCONTRACT',?,?,'STANDARD',20,0,0,0,0,?)
                                """)) {
                            consideration.setObject(1,UUID.randomUUID()); consideration.setObject(2,receipt);
                            consideration.setObject(3,receiptLine); consideration.setObject(4,master.user());
                            consideration.executeUpdate();
                        }
                        try (var source = connection.prepareStatement("""
                                INSERT INTO subcontract_receipt_material_consumptions(
                                    id,receipt_item_id,issue_item_id,qty_doc,qty_base,consumption_basis,created_by)
                                VALUES (?,?,?,22,22,'FROZEN_BOM_ESTIMATE',?)
                                """)) {
                            source.setObject(1,consumption); source.setObject(2,receiptLine);
                            source.setObject(3,issueLine); source.setObject(4,master.user());
                            source.executeUpdate();
                        }
                        for(var historical:Map.of(completedCase,"COMPLETED",acceptedCase,"ACCEPTED_LOSS",openCase,"PENDING_OWNER").entrySet()) {
                            try(var insertCase=connection.prepareStatement("""
                                    INSERT INTO subcontract_short_delivery_cases(id,order_id,order_item_id,order_bill_no_snapshot,
                                      goods_id,unit_id,ordered_qty,allowed_loss_pct,floor_qty,delivered_qty,shortfall_qty,shortfall_pct,
                                      severity,status,decision,decided_at,decided_by_user_id,decided_by_employee_id,closed_at,
                                      loss_qty,loss_pct,detected_by_user_id,detected_by_employee_id)
                                    VALUES(?,?,?,'UP-ORDER',?,?,100,10,90,95,5,5,'WITHIN_TOLERANCE',?,
                                      CASE WHEN ?='ACCEPTED_LOSS' THEN 'ACCEPT_LOSS' ELSE NULL END,
                                      CASE WHEN ?='ACCEPTED_LOSS' THEN now() ELSE NULL END,
                                      CASE WHEN ?='ACCEPTED_LOSS' THEN CAST(? AS uuid) ELSE NULL END,
                                      CASE WHEN ?='ACCEPTED_LOSS' THEN CAST(? AS uuid) ELSE NULL END,
                                      CASE WHEN ?<>'PENDING_OWNER' THEN now() ELSE NULL END,
                                      CASE WHEN ?='ACCEPTED_LOSS' THEN 5 ELSE NULL END,
                                      CASE WHEN ?='ACCEPTED_LOSS' THEN 5 ELSE NULL END,?,?)
                                    """)) {
                                String state=historical.getValue();
                                Object[] values={historical.getKey(),order,item,parent,master.unit(),state,state,state,state,master.user(),
                                        state,master.employee(),state,state,state,master.user(),master.employee()};
                                for(int index=0;index<values.length;index++)insertCase.setObject(index+1,values[index]);
                                insertCase.executeUpdate();
                            }
                        }
                    } catch (java.sql.SQLException failure) {
                        connection.rollback();
                        throw failure;
                    } finally {
                        statement.execute("SET LOCAL session_replication_role=origin");
                    }
                }
                connection.commit();
            }
            db.queryForObject("SELECT fn_assert_subcontract_target_outbound_receipt(?)",Object.class,item);
            Map<String,Object> beforePlan = db.queryForMap(
                    "SELECT planned_qty,issued_qty,bom_unit_qty FROM subcontract_material_plan_items WHERE id=?",line);
            Map<String,Object> beforeIssue = db.queryForMap("""
                    SELECT qty,at_supplier_qty,consumed_qty,frozen_unit_qty,supplier_ending
                    FROM subcontract_material_issue_items WHERE id=?
                    """,issueLine);
            Map<String,Object> beforeConsumption = db.queryForMap(
                    "SELECT * FROM subcontract_receipt_material_consumptions WHERE id=?",consumption);
            String viewBefore = viewMetadata(db);
            String completedBefore=caseSnapshot(db,completedCase),acceptedBefore=caseSnapshot(db,acceptedCase);
            Map<String,String> triggersBefore = new LinkedHashMap<>();
            db.query("""
                    SELECT tgname,tgrelid::regclass::text AS relation,pg_get_triggerdef(oid,true)||':'||tgenabled::text AS definition
                    FROM pg_trigger WHERE tgrelid IN ('subcontract_material_plan_items'::regclass,
                        'subcontract_material_issue_items'::regclass) AND NOT tgisinternal
                    ORDER BY tgname
                    """, row -> {triggersBefore.put(row.getString("relation")+"|"+row.getString("tgname"),row.getString("definition"));});
            TestFlyway.configure().dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                    .locations("classpath:db/migration").target("1098").load().migrate();
            assertEquals(completedBefore,caseSnapshot(db,completedCase),"closed historical threshold, status and event/decision pointers stay unchanged");
            assertEquals(acceptedBefore,caseSnapshot(db,acceptedCase),"authorized historical loss keeps quantity, percent, owner and time");
            assertEquals(1,db.queryForObject("SELECT delivery_policy_version FROM subcontract_short_delivery_cases WHERE id=?",Integer.class,acceptedCase));
            assertEquals(2,db.queryForObject("SELECT delivery_policy_version FROM subcontract_short_delivery_cases WHERE id=?",Integer.class,openCase));
            assertDecimal(new BigDecimal("100"),db.queryForObject("SELECT floor_qty FROM subcontract_short_delivery_cases WHERE id=?",BigDecimal.class,openCase),"live finished target");
            assertEquals("BELOW_FLOOR",db.queryForObject("SELECT severity FROM subcontract_short_delivery_cases WHERE id=?",String.class,openCase));
            beforePlan.forEach((key,value) -> assertDecimal((BigDecimal)value, db.queryForObject(
                    "SELECT " + key + " FROM subcontract_material_plan_items WHERE id=?",BigDecimal.class,line),key));
            beforeIssue.forEach((key,value) -> assertDecimal((BigDecimal)value, db.queryForObject(
                    "SELECT " + key + " FROM subcontract_material_issue_items WHERE id=?",BigDecimal.class,issueLine),key));
            assertEquals(beforeConsumption,db.queryForMap(
                    "SELECT * FROM subcontract_receipt_material_consumptions WHERE id=?",consumption),
                    "historical consumption source slice must keep identity, basis, quantity, actor and time");
            assertDecimal(BigDecimal.ONE,db.queryForObject(
                    "SELECT base_bom_unit_qty FROM subcontract_material_plan_items WHERE id=?",BigDecimal.class,line),"base snapshot");
            assertDecimal(BigDecimal.TEN,db.queryForObject(
                    "SELECT material_loss_pct FROM subcontract_material_plan_items WHERE id=?",BigDecimal.class,line),"historical loss snapshot remains unchanged");
            assertEquals(viewBefore,viewMetadata(db),"dependent view SQL, owner and effective grants survive widening");
            triggersBefore.forEach((identity,definition) -> assertEquals(definition,db.queryForObject("""
                    SELECT pg_get_triggerdef(oid,true)||':'||tgenabled::text FROM pg_trigger
                    WHERE tgname=? AND tgrelid=CAST(? AS regclass)
                    """,String.class,identity.substring(identity.indexOf('|')+1),identity.substring(0,identity.indexOf('|'))),
                    "original guard restored: "+identity));
            db.queryForObject("SELECT fn_assert_subcontract_target_outbound_receipt(?)",Object.class,item);
            assertTrue(db.queryForObject("SELECT fn_subcontract_receipt_material_complete(?)",Boolean.class,receiptLine));
            assertEquals(1,db.queryForObject("SELECT material_consumption_version FROM subcontract_receipt_items WHERE id=?",Integer.class,receiptLine));
            assertDecimal(new BigDecimal("22"),db.queryForObject("SELECT fn_subcontract_material_consumption_target(?)",BigDecimal.class,line),"historical estimate remains22");
            assertDecimal(new BigDecimal("38"),db.queryForObject("SELECT fn_subcontract_physical_receipt_capacity(?)",BigDecimal.class,item),"20 already received plus18 unused base material; historical loss is not reusable");
            try(var connection=DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword())) {
                connection.setAutoCommit(false);
                var failure=org.junit.jupiter.api.Assertions.assertThrows(java.sql.SQLException.class,()->{
                    try(var change=connection.prepareStatement("UPDATE subcontract_receipt_items SET material_consumption_version=2 WHERE id=?")) {
                        change.setObject(1,receiptLine);change.executeUpdate();
                    }
                });
                assertEquals("23514",failure.getSQLState());connection.rollback();
            }

            assertDecimal(new BigDecimal("0.0110"),db.queryForObject(
                    "SELECT fn_subcontract_draw_f(10000,fn_subcontract_supply_unit_qty(0.000001,10))",BigDecimal.class),"minimum usage allowance");
            assertDecimal(new BigDecimal("0.0000010001"),db.queryForObject(
                    "SELECT fn_subcontract_supply_unit_qty(0.000001,0.01)",BigDecimal.class),"tenth fractional digit");
        }
    }

    private static String viewMetadata(JdbcTemplate db) {
        return db.queryForObject("""
                SELECT jsonb_build_object('sql',pg_get_viewdef(relation.oid,true),'owner',pg_get_userbyid(relation.relowner),
                    'acl',(SELECT jsonb_agg(to_jsonb(acl) ORDER BY acl.grantor,acl.grantee,acl.privilege_type)
                           FROM aclexplode(COALESCE(relation.relacl,acldefault('r',relation.relowner))) acl))::text
                FROM pg_class relation WHERE relation.oid='v_procurement_decomposition_tasks'::regclass
                """,String.class);
    }

    private static String caseSnapshot(JdbcTemplate db,UUID id) {
        return db.queryForObject("SELECT (to_jsonb(item)-'delivery_policy_version')::text FROM subcontract_short_delivery_cases item WHERE id=?",String.class,id);
    }

    private static void assertDecimal(BigDecimal expected,BigDecimal actual,String field) {
        assertEquals(0,expected.compareTo(actual),field+" must retain its exact value");
    }
}
