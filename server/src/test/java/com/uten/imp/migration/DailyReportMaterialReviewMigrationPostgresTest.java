package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.TreeMap;
import java.util.TreeSet;
import static org.junit.jupiter.api.Assertions.*;

/** V840 preserves legacy commands; later V852 and V867 schema deltas are explicit and bounded. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class DailyReportMaterialReviewMigrationPostgresTest {
    private static final PostgreSQLContainer<?> pg=new PostgreSQLContainer<>("postgres:16-alpine").withDatabaseName("material_review_upgrade");
    private static JdbcTemplate db;
    private static UUID actor;
    private static Map<String,Object> old;
    private static List<String> tables,indexes,resetPolicy;
    private static Map<String,Object> afterV840;
    private static Object oldMaterialSnapshotAfterV840;
    private static List<String> tablesAfterV840,indexesAfterV840,resetPolicyAfterV840;
    private static final Map<String,String> V852_INDEX_ADDITIONS=Map.ofEntries(
            Map.entry("document_unapprovals_draft_unique","CREATE UNIQUE INDEX document_unapprovals_draft_unique ON public.document_unapprovals USING btree (family, draft_id)"),
            Map.entry("document_unapprovals_original_unique","CREATE UNIQUE INDEX document_unapprovals_original_unique ON public.document_unapprovals USING btree (family, original_id)"),
            Map.entry("document_unapprovals_pkey","CREATE UNIQUE INDEX document_unapprovals_pkey ON public.document_unapprovals USING btree (id)"),
            Map.entry("document_unapprovals_request_unique","CREATE UNIQUE INDEX document_unapprovals_request_unique ON public.document_unapprovals USING btree (created_by, family, request_key)"),
            Map.entry("procurement_inspection_items_item_tranche_uk","CREATE UNIQUE INDEX procurement_inspection_items_item_tranche_uk ON public.procurement_inspection_items USING btree (receipt_type, receipt_item_id, quantity_tranche)"),
            Map.entry("idx_purchase_receipt_item_finance_case","CREATE INDEX idx_purchase_receipt_item_finance_case ON public.purchase_receipt_items USING btree (finance_approval_case_id)"),
            Map.entry("idx_subcontract_receipt_item_finance_case","CREATE INDEX idx_subcontract_receipt_item_finance_case ON public.subcontract_receipt_items USING btree (finance_approval_case_id)"),
            Map.entry("idx_purchase_request_qty_revision_document","CREATE INDEX idx_purchase_request_qty_revision_document ON public.purchase_request_qty_revisions USING btree (request_id, request_item_id, expected_version)"),
            Map.entry("purchase_request_qty_revision_request_item_id_expected_vers_key","CREATE UNIQUE INDEX purchase_request_qty_revision_request_item_id_expected_vers_key ON public.purchase_request_qty_revisions USING btree (request_item_id, expected_version)"),
            Map.entry("purchase_request_qty_revisions_created_txid_request_item_id_key","CREATE UNIQUE INDEX purchase_request_qty_revisions_created_txid_request_item_id_key ON public.purchase_request_qty_revisions USING btree (created_txid, request_item_id)"),
            Map.entry("purchase_request_qty_revisions_pkey","CREATE UNIQUE INDEX purchase_request_qty_revisions_pkey ON public.purchase_request_qty_revisions USING btree (id)"),
            Map.entry("idx_poi_price_context","CREATE INDEX idx_poi_price_context ON public.purchase_order_items USING btree (goods_id, color_id, unit_id, unit_rate, order_id) WHERE (NOT is_deleted)"),
            Map.entry("idx_sori_price_context","CREATE INDEX idx_sori_price_context ON public.subcontract_order_items USING btree (goods_id, color_id, unit_id, unit_rate, order_id) WHERE (NOT is_deleted)"),
            Map.entry("idx_soi_price_context","CREATE INDEX idx_soi_price_context ON public.sales_order_items USING btree (goods_id, color_id, unit_id, unit_rate, order_id) WHERE (NOT is_deleted)"),
            Map.entry("idx_po_price_period","CREATE INDEX idx_po_price_period ON public.purchase_orders USING btree (bill_date DESC, id) WHERE ((status = 1) AND (NOT is_deleted))"),
            Map.entry("idx_sco_price_period","CREATE INDEX idx_sco_price_period ON public.subcontract_orders USING btree (bill_date DESC, id) WHERE ((status = 1) AND (NOT is_deleted))"),
            Map.entry("idx_so_price_period","CREATE INDEX idx_so_price_period ON public.sales_orders USING btree (bill_date DESC, id) WHERE ((status = 1) AND (NOT is_deleted))"),
            Map.entry("idx_procurement_price_history_snapshot","CREATE INDEX idx_procurement_price_history_snapshot ON public.procurement_order_approval_cases USING gin (submission_snapshot jsonb_path_ops)"));
    @BeforeAll static void migrate() {
        pg.start();Flyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).locations("classpath:db/migration").target("839").load().migrate();
        db=new JdbcTemplate(new DriverManagerDataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()));
        actor=UUID.randomUUID();UUID department=UUID.randomUUID(),employee=UUID.randomUUID(),report=UUID.randomUUID();
        db.update("INSERT INTO departments(id,code,name,level) VALUES(?,?,?,'一级部门')",department,"MAT-V3-D","材料审核迁移车间");
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,CURRENT_DATE,'active','regular')",employee,"MAT-V3-E","材料审核迁移员工",department);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) VALUES(?,?,?,'test-only','active',FALSE)",actor,employee,"material-review-migration");
        db.update("INSERT INTO production_daily_reports(id,bill_no,bill_date,status,maker_id) VALUES(?,'SR20200101000001',DATE '2020-01-01',0,?)",report,employee);
        db.update("INSERT INTO production_daily_report_commands(actor_user_id,idempotency_key,request_hash,report_id,created_by,command_kind,approval_protocol_version,reviewed_row_version) VALUES(?,? ,repeat('a',64),?,?,'APPROVE',2,0)",actor,"old-reviewed-material-key",report,actor);
        old=db.queryForMap("SELECT report_id,request_hash,approval_protocol_version,reviewed_row_version,xmin::text row_xmin FROM production_daily_report_commands WHERE actor_user_id=?",actor);
        tables=tables();indexes=indexes();resetPolicy=resetPolicy();
        Flyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).locations("classpath:db/migration").target("840").load().migrate();
        afterV840=oldCommand();
        oldMaterialSnapshotAfterV840=db.queryForObject("SELECT material_review_snapshot FROM production_daily_report_commands WHERE actor_user_id=?",Object.class,actor);
        tablesAfterV840=tables();indexesAfterV840=indexes();resetPolicyAfterV840=resetPolicy();
        Flyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).locations("classpath:db/migration").load().migrate();
    }
    @AfterAll static void stop(){pg.stop();}
    @Test void oldApprovalBytesAndReviewMeaningStayExactlyTheSame() {
        assertEquals(old,afterV840);
        assertNull(oldMaterialSnapshotAfterV840);
        assertEquals(old,oldCommand());
        assertNull(db.queryForObject("SELECT material_review_snapshot FROM production_daily_report_commands WHERE actor_user_id=?",Object.class,actor));
        assertEquals(tables,tablesAfterV840);assertEquals(indexes,indexesAfterV840);assertEquals(resetPolicy,resetPolicyAfterV840);
    }
    @Test void laterForwardMigrationsHaveOnlyTheExactDeclaredV852AndV867SchemaDelta() {
        TreeSet<String> expectedTables=new TreeSet<>(tablesAfterV840);
        assertTrue(expectedTables.add("document_unapprovals"));
        assertTrue(expectedTables.add("purchase_request_qty_revisions"));
        assertTrue(expectedTables.add("sms_gateway_settings"));
        assertEquals(expectedTables.stream().toList(),tables());
        TreeMap<String,String> expectedIndexes=catalogMap(indexesAfterV840);
        assertEquals("CREATE UNIQUE INDEX procurement_inspection_items_item_uk ON public.procurement_inspection_items USING btree (receipt_type, receipt_item_id)",
                expectedIndexes.remove("procurement_inspection_items_item_uk"));
        V852_INDEX_ADDITIONS.forEach((name,definition)->assertNull(expectedIndexes.put(name,definition),
                "A declared new index must not replace an existing index: "+name));
        assertNull(expectedIndexes.put("sms_gateway_settings_pkey",
                "CREATE UNIQUE INDEX sms_gateway_settings_pkey ON public.sms_gateway_settings USING btree (id)"));
        assertEquals(expectedIndexes,catalogMap(indexes()));
        TreeMap<String,String> expectedPolicy=catalogMap(resetPolicyAfterV840);
        assertNull(expectedPolicy.put("document_unapprovals","CLEAR"));
        assertNull(expectedPolicy.put("purchase_request_qty_revisions","CLEAR"));
        assertNull(expectedPolicy.put("sms_gateway_settings","PRESERVE"));
        assertEquals(expectedPolicy,catalogMap(resetPolicy()));
        assertEquals(MigrationRehearsalSupport.CURRENT_HEAD_VERSION,
                db.queryForObject("SELECT version FROM flyway_schema_history WHERE success ORDER BY installed_rank DESC LIMIT 1",String.class));
    }
    @Test void incompleteV3ProofOrForeignReportSnapshotCannotBeRecorded() {
        UUID report=newReport("SR20200101000002");
        assertThrows(Exception.class,()->insertV3(report,"{\"reportId\":\""+report+"\",\"reportVersion\":0,\"fingerprint\":\""+"b".repeat(64)+"\",\"rows\":[]}",null));
        assertThrows(Exception.class,()->insertV3(report,"{}","[]"));
        assertThrows(Exception.class,()->insertV3(report,"{\"reportId\":\""+UUID.randomUUID()+"\",\"reportVersion\":0,\"fingerprint\":\""+"b".repeat(64)+"\",\"rows\":[]}","[]"));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_daily_report_commands WHERE report_id=?",Integer.class,report));
    }
    @Test void validV3EmptyMaterialSnapshotIsAppendOnlyAndUsesExistingResetPolicy() {
        UUID report=newReport("SR20200101000003");
        insertV3(report,"{\"reportId\":\""+report+"\",\"reportVersion\":0,\"fingerprint\":\""+"b".repeat(64)+"\",\"rows\":[]}","[]");
        assertThrows(Exception.class,()->db.update("UPDATE production_daily_report_commands SET material_decisions='[]'::jsonb WHERE report_id=?",report));
        assertThrows(Exception.class,()->db.update("DELETE FROM production_daily_report_commands WHERE report_id=?",report));
        assertEquals(3,db.queryForObject("SELECT approval_protocol_version FROM production_daily_report_commands WHERE report_id=?",Integer.class,report));
        assertTrue(resetPolicy().stream().anyMatch(row->row.startsWith("production_daily_report_commands|")));
    }
    private static UUID newReport(String billNo){UUID report=UUID.randomUUID();UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,actor);db.update("INSERT INTO production_daily_reports(id,bill_no,bill_date,status,maker_id) VALUES(?,?,DATE '2020-01-01',0,?)",report,billNo,employee);return report;}
    private static Map<String,Object> oldCommand(){return db.queryForMap("SELECT report_id,request_hash,approval_protocol_version,reviewed_row_version,xmin::text row_xmin FROM production_daily_report_commands WHERE actor_user_id=?",actor);}
    private static TreeMap<String,String> catalogMap(List<String> rows){TreeMap<String,String> result=new TreeMap<>();for(String row:rows){int separator=row.indexOf('|');assertTrue(separator>0);assertNull(result.put(row.substring(0,separator),row.substring(separator+1)));}return result;}
    private static void insertV3(UUID report,String snapshot,String decisions){db.update("INSERT INTO production_daily_report_commands(actor_user_id,idempotency_key,request_hash,report_id,created_by,command_kind,approval_protocol_version,reviewed_row_version,material_review_fingerprint,material_review_snapshot,material_decisions) VALUES(?,?,repeat('b',64),?,?,'APPROVE',3,0,repeat('b',64),CAST(? AS jsonb),CAST(? AS jsonb))",actor,"new-v3-migration-"+UUID.randomUUID(),report,actor,snapshot,decisions);}
    private static List<String> tables(){return db.queryForList("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename",String.class);}
    private static List<String> indexes(){return db.queryForList("SELECT indexname||'|'||indexdef FROM pg_indexes WHERE schemaname='public' ORDER BY indexname",String.class);}
    private static List<String> resetPolicy(){return db.queryForList("SELECT table_name||'|'||disposition FROM fn_business_reset_table_policy() ORDER BY table_name",String.class);}
}
