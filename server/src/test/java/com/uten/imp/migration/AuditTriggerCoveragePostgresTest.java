package com.uten.imp.migration;

import com.uten.imp.application.port.InventoryOpeningPort.Opening;
import com.uten.imp.application.port.InventoryOpeningPort.OpeningValue;
import com.uten.imp.application.port.InventoryValuationPort.EventContext;
import com.uten.imp.application.port.InventoryValuationPort.PoolKey;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.features.stock.valuation.InventoryOpeningService;
import jakarta.persistence.EntityManagerFactory;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.DriverManager;
import java.time.OffsetDateTime;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;

/** Nonempty forward upgrade, real value evidence, and fail-closed audit DDL. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class AuditTriggerCoveragePostgresTest {
    private static final PostgreSQLContainer<?> DB=new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID USER=UUID.randomUUID(),EMPLOYEE=UUID.randomUUID(),WAREHOUSE=UUID.randomUUID(),UNIT=UUID.randomUUID();
    private static JdbcTemplate db;
    private static EntityManagerFactory emf;
    private static TransactionTemplate transactions;
    private static InventoryMutationLock mutex;
    private static InventoryOpeningService openings;
    private static String migration,oldBusiness,oldAudit,oldValidTriggers;
    private static OpeningValue oldOpening;

    @BeforeAll static void start() throws Exception {
        DB.start();
        Flyway.configure().dataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword())
                .locations("classpath:db/migration").target("529").load().migrate();
        var source=new DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());db=new JdbcTemplate(source);
        db.update("INSERT INTO units(id,code,name) VALUES(?,?,'piece')",UNIT,"AUDIT-UNIT-"+UNIT);
        db.update("INSERT INTO warehouses(id,code,name) VALUES(?,?,'audit fixture warehouse')",WAREHOUSE,"AUDIT-WH-"+WAREHOUSE);
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',(SELECT id FROM departments WHERE code='WS_ZHUSU' AND NOT is_deleted),DATE '2026-01-01','active','regular')",EMPLOYEE,"AUDIT-EMP-"+EMPLOYEE,"audit source employee");
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status) VALUES(?,?,?,'test-only-unused-password','active')",USER,EMPLOYEE,"audit-source-"+USER);
        var factory=new LocalContainerEntityManagerFactoryBean();factory.setDataSource(source);
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());factory.setPackagesToScan("com.uten.imp.features.common.taskclaim");
        Properties properties=new Properties();properties.setProperty("hibernate.hbm2ddl.auto","none");factory.setJpaProperties(properties);factory.afterPropertiesSet();
        emf=factory.getObject();var em=SharedEntityManagerCreator.createSharedEntityManager(emf);
        transactions=new TransactionTemplate(new JpaTransactionManager(emf));mutex=new InventoryMutationLock(em);
        openings=new InventoryOpeningService(new NamedParameterJdbcTemplate(source),mutex);
        oldOpening=openPending();
        assertEquals(0,db.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='stock_value_openings' AND target_id=?",Integer.class,oldOpening.eventId().toString()));
        oldBusiness=db.queryForObject("SELECT to_jsonb(opening)::text FROM stock_value_openings opening WHERE event_id=?",String.class,oldOpening.eventId());
        oldAudit=auditSnapshot();oldValidTriggers=validTriggerSnapshot();
        migration=Files.readString(Path.of("src/main/resources/db/migration/V530__refresh_audit_trigger_coverage.sql"));
        Flyway.configure().dataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword()).locations("classpath:db/migration").load().migrate();
    }
    @AfterAll static void stop(){if(emf!=null)emf.close();DB.stop();}

    @Test void upgradePreservesOldFactsAndAuditAndDoesNotDuplicateValidTriggers(){
        assertEquals(oldBusiness,db.queryForObject("SELECT to_jsonb(opening)::text FROM stock_value_openings opening WHERE event_id=?",String.class,oldOpening.eventId()));
        assertEquals(oldAudit,auditSnapshotBeforeUpgrade());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='stock_value_openings' AND target_id=?",Integer.class,oldOpening.eventId().toString()),"no historical audit backfill");
        assertEquals(oldValidTriggers,validOldTriggerSnapshot());
        for(String table:List.of("procurement_order_source_revisions","procurement_order_source_revision_allocations","procurement_order_source_revision_peg_changes",
                "stock_value_pools","stock_value_events","stock_value_nodes","stock_value_edges","stock_value_jobs","stock_value_tasks","stock_value_node_revisions","stock_value_postings",
                "stock_value_openings","stock_value_legacy_balance_cases","stock_value_legacy_balance_case_events","stock_value_acquisition_sources","stock_value_position_transfers",
                "stock_value_production_cost_objects","stock_value_production_cost_inputs","stock_value_production_cost_outputs","stock_value_production_cost_revisions",
                "stock_value_production_cost_tasks","stock_value_production_cost_shares","stock_value_production_cost_dirty","production_material_movement_links",
                "procurement_receipt_consideration_parts","procurement_iqc_quality_consideration_parts","procurement_iqc_funding_slices","procurement_iqc_credit_documents",
                "procurement_iqc_credit_case_allocations","procurement_iqc_credit_slices","procurement_iqc_stock_consideration_parts","procurement_iqc_funding_settlements",
                "procurement_iqc_consideration_reversals","procurement_iqc_consideration_review_approvals","subcontract_receipt_material_consumptions")){
            assertEquals(1,db.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgrelid=?::regclass AND NOT tgisinternal AND tgname LIKE 'trg_audit%' AND tgtype=29 AND tgenabled IN('O','A') AND tgnargs=0 AND tgqual IS NULL AND tgattr=''::int2vector AND tgfoid IN('public.fn_audit()'::regprocedure,'public.fn_audit_redacted()'::regprocedure)",Integer.class,table),table);
        }
        for(String table:List.of("notices","notice_user_states","notice_acknowledgments","notice_blessings","notice_celebration_subjects","business_outbox","attachment_object_outbox","account_flow_monthly_summaries","production_daily_report_commands","production_fqc_release_commands","warehouse_arrival_registration_commands","production_material_analysis_commands","master_code_sequences"))
            assertEquals(0,db.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgrelid=?::regclass AND NOT tgisinternal AND tgname LIKE 'trg_audit%'",Integer.class,table),table);
    }

    @Test void realValueWriteKeepsStableEventIdentityAndOriginalActorWithoutAFakeWorkerSession(){
        OpeningValue value=openPending();
        var audit=db.queryForMap("SELECT actor_id,\"after\"->>'event_id' event_id,\"after\"->>'observed_recorded_value' amount,jsonb_exists(\"after\",'before_balance') raw_snapshot FROM audit_log WHERE target_type='stock_value_openings' AND target_id=? AND action='insert'",value.eventId().toString());
        assertNull(audit.get("actor_id"),"there is no authenticated worker session; do not invent an executor");
        assertEquals(value.eventId().toString(),audit.get("event_id"));assertEquals(0,new BigDecimal(audit.get("amount").toString()).compareTo(new BigDecimal("84")));
        assertEquals(false,audit.get("raw_snapshot"));
        assertEquals(USER.toString(),db.queryForObject("SELECT \"after\"->>'actor_user_id' FROM audit_log WHERE target_type='stock_value_events' AND target_id=? AND action='insert'",String.class,value.eventId().toString()));
        assertEquals(false,db.queryForObject("SELECT jsonb_exists(\"after\",'request_payload') FROM audit_log WHERE target_type='stock_value_events' AND target_id=? AND action='insert'",Boolean.class,value.eventId().toString()));
        assertEquals(USER,db.queryForObject("SELECT event.actor_user_id FROM stock_value_openings opening JOIN stock_value_events event ON event.id=opening.event_id WHERE opening.event_id=?",UUID.class,value.eventId()));
        String first=db.queryForObject("SELECT fn_audit_primary_key_identity('stock_value_production_cost_outputs'::regclass,jsonb_build_object('execution_segment_id',?::uuid,'source_node_id',?::uuid,'qty_base',1))",String.class,UUID.fromString("00000000-0000-0000-0000-000000000001"),value.sourceCostNodeId());
        String second=db.queryForObject("SELECT fn_audit_primary_key_identity('stock_value_production_cost_outputs'::regclass,jsonb_build_object('execution_segment_id',?::uuid,'source_node_id',?::uuid,'qty_base',9))",String.class,UUID.fromString("00000000-0000-0000-0000-000000000001"),value.sourceCostNodeId());
        assertEquals(first,second);assertTrue(first.contains("execution_segment_id")&&first.contains("source_node_id"));
    }

    @Test void currentSweepRepairsMissingAuditAndReplaysWithoutDuplicateRows() throws Exception {
        try(var connection=connection();var statement=connection.createStatement()){
            connection.setAutoCommit(false);
            try{statement.execute("DROP TRIGGER trg_audit_stock_value_tasks ON stock_value_tasks");statement.execute(migration);statement.execute(migration);
                try(var rows=statement.executeQuery("SELECT count(*) FROM pg_trigger WHERE tgrelid='stock_value_tasks'::regclass AND tgname LIKE 'trg_audit%' AND tgtype=29 AND tgenabled='A'")){rows.next();assertEquals(1,rows.getInt(1));}
            }finally{connection.rollback();}
        }
    }

    @Test void singlePrimaryKeyIncludeUpdateKeepsTheSameAuditIdentity() throws Exception {
        assertIncludedQuantityDoesNotChangeAuditIdentity(false);
    }

    @Test void compoundPrimaryKeyIncludeUpdateKeepsTheSameAuditIdentity() throws Exception {
        assertIncludedQuantityDoesNotChangeAuditIdentity(true);
    }

    private static void assertIncludedQuantityDoesNotChangeAuditIdentity(boolean compound) throws Exception {
        String table=compound?"audit_compound_pk_include_probe":"audit_single_pk_include_probe";
        UUID root=UUID.randomUUID();
        try(var connection=connection();var statement=connection.createStatement()){
            connection.setAutoCommit(false);
            try{
                statement.execute("CREATE TEMP TABLE "+table+"(root_key UUID NOT NULL,slice_no INTEGER NOT NULL,quantity NUMERIC NOT NULL,PRIMARY KEY(root_key"+(compound?",slice_no":"")+") INCLUDE(quantity)) ON COMMIT DROP");
                statement.execute("CREATE TRIGGER trg_audit_include_probe AFTER INSERT OR UPDATE OR DELETE ON "+table+" FOR EACH ROW EXECUTE FUNCTION public.fn_audit()");
                try(var rows=statement.executeQuery("SELECT indnkeyatts,indnatts FROM pg_index WHERE indrelid='pg_temp."+table+"'::regclass AND indisprimary")){
                    assertTrue(rows.next());assertEquals(compound?2:1,rows.getInt(1));assertEquals(compound?3:2,rows.getInt(2));
                }
                statement.execute("INSERT INTO "+table+" VALUES('"+root+"',2,1)");
                statement.execute("UPDATE "+table+" SET quantity=9");
                statement.execute("DELETE FROM "+table);
                try(var query=connection.prepareStatement("SELECT action,target_id,\"before\"->>'quantity',\"after\"->>'quantity',CASE WHEN ? THEN target_id::jsonb=jsonb_build_object('root_key',?::uuid,'slice_no',2) ELSE target_id=? END AS expected_identity FROM audit_log WHERE target_type=? ORDER BY id")){
                    query.setBoolean(1,compound);query.setObject(2,root);query.setString(3,root.toString());query.setString(4,table);
                    try(var rows=query.executeQuery()){
                        String identity=null;
                        for(String action:List.of("insert","update","delete")){
                            assertTrue(rows.next());assertEquals(action,rows.getString(1));assertTrue(rows.getBoolean(5),"only actual primary-key attributes identify the row");
                            if(identity==null)identity=rows.getString(2);else assertEquals(identity,rows.getString(2),"changing an INCLUDE value must not split the audit history");
                            if(action.equals("insert")){assertNull(rows.getString(3));assertEquals("1",rows.getString(4));}
                            else if(action.equals("update")){assertEquals("1",rows.getString(3));assertEquals("9",rows.getString(4));}
                            else {assertEquals("9",rows.getString(3));assertNull(rows.getString(4));}
                        }
                        assertFalse(rows.next());
                    }
                }
            }finally{connection.rollback();}
        }
    }

    @Test void unknownSameNameShapesAndHiddenDuplicateAuditAreRejected() throws Exception {
        for(String ddl:List.of(
                "CREATE TRIGGER trg_audit_stock_value_events BEFORE INSERT OR UPDATE OR DELETE ON stock_value_events FOR EACH ROW EXECUTE FUNCTION fn_audit()",
                "CREATE TRIGGER trg_audit_stock_value_events AFTER INSERT ON stock_value_events FOR EACH ROW EXECUTE FUNCTION fn_audit()",
                "CREATE TRIGGER trg_audit_stock_value_events AFTER INSERT OR UPDATE OR DELETE ON stock_value_events FOR EACH ROW WHEN(pg_trigger_depth()>=0) EXECUTE FUNCTION fn_audit()",
                "CREATE TRIGGER trg_audit_stock_value_events AFTER INSERT OR UPDATE OF id OR DELETE ON stock_value_events FOR EACH ROW EXECUTE FUNCTION fn_audit()",
                "CREATE TRIGGER trg_audit_stock_value_events AFTER INSERT OR UPDATE OR DELETE ON stock_value_events FOR EACH ROW EXECUTE FUNCTION audit_test_noop()",
                "CREATE TRIGGER trg_audit_stock_value_events AFTER INSERT OR UPDATE OR DELETE ON stock_value_events FOR EACH ROW EXECUTE FUNCTION fn_audit(); ALTER TABLE stock_value_events DISABLE TRIGGER trg_audit_stock_value_events",
                "CREATE TRIGGER trg_audit_stock_value_events AFTER INSERT OR UPDATE OR DELETE ON stock_value_events FOR EACH ROW EXECUTE FUNCTION fn_audit(); ALTER TABLE stock_value_events ENABLE REPLICA TRIGGER trg_audit_stock_value_events",
                "CREATE TRIGGER trg_audit_stock_value_events AFTER INSERT OR UPDATE OR DELETE ON stock_value_events FOR EACH ROW EXECUTE FUNCTION fn_audit(); CREATE TRIGGER hidden_duplicate AFTER INSERT OR UPDATE OR DELETE ON stock_value_events FOR EACH ROW EXECUTE FUNCTION fn_audit()")){
            try(var connection=connection();var statement=connection.createStatement()){
                connection.setAutoCommit(false);
                try{statement.execute("CREATE FUNCTION audit_test_noop() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN COALESCE(NEW,OLD); END $$");
                    statement.execute("DROP TRIGGER trg_audit_stock_value_events ON stock_value_events");statement.execute(ddl);
                    var failure=assertThrows(PSQLException.class,()->statement.execute(migration),ddl);assertEquals("55000",failure.getSQLState());
                }finally{connection.rollback();}
            }
        }
        try(var connection=connection();var statement=connection.createStatement()){
            connection.setAutoCommit(false);
            try{statement.execute("CREATE FUNCTION audit_test_noop() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN COALESCE(NEW,OLD); END $$");
                statement.execute("DROP TRIGGER trg_audit_procurement_order_source_revision_allocations ON procurement_order_source_revision_allocations; CREATE TRIGGER trg_audit_procurement_order_source_revision_allocations AFTER INSERT ON procurement_order_source_revision_allocations FOR EACH ROW EXECUTE FUNCTION audit_test_noop()");
                assertEquals("55000",assertThrows(PSQLException.class,()->statement.execute(migration)).getSQLState(),"the V503 exception cannot wash an unknown function");
            }finally{connection.rollback();}
        }
    }

    private static OpeningValue openPending(){
        UUID goods=UUID.randomUUID(),balance=UUID.randomUUID(),sourceEvent=UUID.randomUUID();
        db.update("INSERT INTO goods(id,code,name,unit_id,code_sequence) VALUES(?,?,'audit value source',?,(SELECT COALESCE(max(code_sequence),0)+1 FROM goods))",goods,"AUDIT-G-"+goods,UNIT);
        db.update("INSERT INTO stock_balances(id,warehouse_id,goods_id,qty,amount_local) VALUES(?,?,?,7,84)",balance,WAREHOUSE,goods);
        PoolKey key=new PoolKey(WAREHOUSE,goods,null);
        return transactions.execute(status->{
            db.execute("SELECT set_config('app.actor_id','',true)");db.execute("SELECT set_config('app.actor_account','',true)");
            mutex.lock(new InventoryKey(goods,null));
            EventContext context=new EventContext(sourceEvent,"INVENTORY_OPENING",balance,balance,1,USER,EMPLOYEE,"audit-opening-"+sourceEvent,OffsetDateTime.now());
            return openings.open(new Opening(context,key,new BigDecimal("7"),new BigDecimal("84"),null,false,"原记录金额待核定；保留原事件责任人"));
        });
    }
    private static java.sql.Connection connection() throws Exception{return DriverManager.getConnection(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());}
    private static String auditSnapshot(){return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(audit) ORDER BY id),'[]'::jsonb)::text FROM audit_log audit",String.class);}
    private static String auditSnapshotBeforeUpgrade(){return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(audit) ORDER BY id),'[]'::jsonb)::text FROM audit_log audit WHERE id IN(SELECT (value->>'id')::bigint FROM jsonb_array_elements(?::jsonb))",String.class,oldAudit);}
    private static String validTriggerSnapshot(){return db.queryForObject("SELECT COALESCE(jsonb_agg(jsonb_build_object('oid',t.oid,'name',t.tgname,'enabled',t.tgenabled,'function',t.tgfoid,'type',t.tgtype) ORDER BY t.oid),'[]'::jsonb)::text FROM pg_trigger t WHERE NOT t.tgisinternal AND t.tgname LIKE 'trg_audit%' AND t.tgtype=29 AND t.tgenabled IN('O','A')",String.class);}
    private static String validOldTriggerSnapshot(){return db.queryForObject("SELECT COALESCE(jsonb_agg(jsonb_build_object('oid',t.oid,'name',t.tgname,'enabled',t.tgenabled,'function',t.tgfoid,'type',t.tgtype) ORDER BY t.oid),'[]'::jsonb)::text FROM pg_trigger t WHERE t.oid IN(SELECT (value->>'oid')::oid FROM jsonb_array_elements(?::jsonb))",String.class,oldValidTriggers);}
}
