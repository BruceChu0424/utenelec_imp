package com.uten.imp.migration;

import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;

/** Isolates V1129's temporal proof; real issue/report commands are covered by the business-chain suite. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class PartialMaterialReportCapacityPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("partial_capacity").withUsername("fixture_admin").withPassword("test-only");
    private static JdbcTemplate db;
    private static TransactionTemplate tx;
    private UUID segment,demand;

    @BeforeAll static void migrate() throws Exception {
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source);tx=new TransactionTemplate(new DataSourceTransactionManager(source));
        db.execute("""
            CREATE TABLE production_execution_segments(id uuid PRIMARY KEY,planned_qty numeric,material_requirement_mode text,is_deleted boolean DEFAULT false);
            CREATE TABLE production_material_demands(id uuid PRIMARY KEY,execution_segment_id uuid,required_qty numeric,material_increment_request_id uuid,status text DEFAULT 'PARTIAL',is_deleted boolean DEFAULT false);
            CREATE TABLE production_material_stock_postings(id uuid PRIMARY KEY,event_id uuid,demand_id uuid,source_posting_id uuid,posting_type text,qty_base numeric);
            CREATE TABLE production_daily_reports(id uuid PRIMARY KEY,status int,is_deleted boolean DEFAULT false);
            CREATE TABLE production_daily_report_items(id uuid PRIMARY KEY,report_id uuid,execution_segment_id uuid,qty numeric,fqc_recovery_authorization_id uuid,is_deleted boolean DEFAULT false);
            CREATE FUNCTION fn_execution_material_output_capacity(p_segment uuid,p_issued boolean) RETURNS numeric LANGUAGE sql STABLE AS $$
              SELECT COALESCE(MIN(LEAST(segment.planned_qty,GREATEST(COALESCE((SELECT SUM(CASE posting_type WHEN 'ISSUE' THEN qty_base WHEN 'GOOD_RETURN_REVERSE' THEN qty_base ELSE -qty_base END)
                FROM production_material_stock_postings WHERE demand_id=demand.id),0),0)*segment.planned_qty/demand.required_qty)),0)
              FROM production_execution_segments segment JOIN production_material_demands demand ON demand.execution_segment_id=segment.id WHERE segment.id=p_segment;
            $$;
            CREATE ROLE capacity_runtime;
            CREATE ROLE capacity_reader;
            GRANT INSERT ON production_material_stock_postings TO capacity_runtime;
            GRANT SELECT ON production_material_stock_postings TO capacity_reader;
            ALTER DEFAULT PRIVILEGES GRANT ALL ON SEQUENCES TO capacity_runtime;
            """);
        UUID historical=UUID.randomUUID();
        db.update("INSERT INTO production_material_stock_postings(id,event_id,demand_id,posting_type,qty_base) VALUES(?,?,?,'ISSUE',5)",historical,UUID.randomUUID(),UUID.randomUUID());
        db.execute(Files.readString(Path.of("src/main/resources/db/migration/V1129__partial_material_reporting_capacity.sql")));
        assertNull(db.queryForObject("SELECT ledger_order FROM production_material_stock_postings WHERE id=?",Long.class,historical),"migration must not invent historical order");
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void fixture(){
        db.execute("TRUNCATE production_daily_report_items,production_daily_reports,production_material_stock_postings,production_material_demands,production_execution_segments");
        segment=UUID.randomUUID();demand=UUID.randomUUID();
        db.update("INSERT INTO production_execution_segments(id,planned_qty,material_requirement_mode) VALUES(?,10,'DEMANDED')",segment);
        db.update("INSERT INTO production_material_demands(id,execution_segment_id,required_qty) VALUES(?,?,10)",demand,segment);
    }
    @Test void repeatedReturnAndReissueNeverInventsAFullKit(){
        UUID first=post(demand,"ISSUE","5",null);
        post(demand,"GOOD_RETURN","5",first);post(demand,"ISSUE","5",null);
        amount("5",room(null));
    }
    @Test void materialPeaksMustOverlapAtOneCommonEventPrefix(){
        UUID other=UUID.randomUUID();db.update("UPDATE production_execution_segments SET planned_qty=5 WHERE id=?",segment);
        db.update("UPDATE production_material_demands SET required_qty=5 WHERE id=?",demand);
        db.update("INSERT INTO production_material_demands(id,execution_segment_id,required_qty) VALUES(?,?,5)",other,segment);
        UUID first=post(demand,"ISSUE","5",null);post(demand,"GOOD_RETURN","5",first);
        post(other,"ISSUE","5",null);amount("0",room(null));
    }
    @Test void aRealCompleteCommonPrefixRetainsItsYieldContractAfterReturn(){
        UUID first=post(demand,"ISSUE","5",null);post(demand,"ISSUE","5",null);
        post(demand,"GOOD_RETURN","3",first);assertNull(room(null));
    }
    @Test void issueReversalRetiresTheOriginalFullIssueProof(){
        UUID first=post(demand,"ISSUE","10",null);
        post(demand,"ISSUE_REVERSE","1",first);amount("9",room(null));
        post(demand,"ISSUE","1",null);assertNull(room(null));
    }
    @Test void oneEventWithSeveralPhysicalPostingSlicesIsAtomic(){
        UUID other=UUID.randomUUID(),event=UUID.randomUUID();
        db.update("INSERT INTO production_material_demands(id,execution_segment_id,required_qty) VALUES(?,?,10)",other,segment);
        UUID first=post(event,demand,"ISSUE","10",null,false);
        post(event,other,"ISSUE","4",null,false);post(event,other,"ISSUE","6",null,false);
        post(demand,"GOOD_RETURN","10",first);assertNull(room(null));
    }
    @Test void unknownHistoricalOrderIsConservativeButACompleteSingleIssueIsProvable(){
        UUID first=post(UUID.randomUUID(),demand,"ISSUE","5",null,true);
        post(UUID.randomUUID(),demand,"ISSUE","5",null,true);
        post(UUID.randomUUID(),demand,"GOOD_RETURN","3",first,true);amount("7",room(null));
        db.execute("TRUNCATE production_material_stock_postings");
        first=post(UUID.randomUUID(),demand,"ISSUE","10",null,true);
        post(UUID.randomUUID(),demand,"GOOD_RETURN","3",first,true);assertNull(room(null));
    }
    @Test void allActiveOutputIncludingDraftsConsumesRoomAndEditingExcludesOnlyItsOwnReport(){
        post(demand,"ISSUE","5",null);
        UUID draft=report(0,"2"),approved=report(1,"1");report(2,"100");report(0,"0.5");
        amount("1.5",room(null));amount("3.5",room(draft));amount("2.5",room(approved));
    }
    @Test void sequenceGapsOnRollbackDoNotBecomeInventoryOrOutput(){
        tx.executeWithoutResult(status->{post(demand,"ISSUE","10",null);status.setRollbackOnly();});
        post(demand,"ISSUE","5",null);amount("5",room(null));
        assertTrue(db.queryForObject("SELECT ledger_order FROM production_material_stock_postings",Long.class)>1);
    }
    @Test void sequencePermissionFollowsExistingInsertAccessWithoutGrantingSetval(){
        assertTrue(db.queryForObject("SELECT has_sequence_privilege('capacity_runtime','production_material_stock_posting_order_seq','USAGE')",Boolean.class));
        assertFalse(db.queryForObject("SELECT has_sequence_privilege('capacity_runtime','production_material_stock_posting_order_seq','UPDATE')",Boolean.class));
        assertFalse(db.queryForObject("SELECT has_sequence_privilege('capacity_reader','production_material_stock_posting_order_seq','USAGE')",Boolean.class));
    }
    @Test void demandLockOrderRemainsCorrectWhenSecondTransactionStartsBeforeFirstPosting() throws Exception {
        var locked=new CountDownLatch(1);var secondStarted=new CountDownLatch(1);var issue=new AtomicReference<UUID>();
        try(var workers=Executors.newFixedThreadPool(2)) {
            var first=workers.submit(()->tx.executeWithoutResult(status->{
                db.queryForObject("SELECT id FROM production_material_demands WHERE id=? FOR UPDATE",UUID.class,demand);locked.countDown();
                await(secondStarted);issue.set(post(demand,"ISSUE","5",null));
            }));
            var second=workers.submit(()->{await(locked);tx.executeWithoutResult(status->{
                db.queryForObject("SELECT now()",java.sql.Timestamp.class);secondStarted.countDown();
                db.queryForObject("SELECT id FROM production_material_demands WHERE id=? FOR UPDATE",UUID.class,demand);
                post(demand,"GOOD_RETURN","5",issue.get());
            });});
            first.get(20,TimeUnit.SECONDS);second.get(20,TimeUnit.SECONDS);
        }
        assertEquals(java.util.List.of("ISSUE","GOOD_RETURN"),db.queryForList("SELECT posting_type FROM production_material_stock_postings ORDER BY ledger_order",String.class));
        amount("0",room(null));
    }
    private static void await(CountDownLatch latch){try{assertTrue(latch.await(15,TimeUnit.SECONDS));}catch(InterruptedException error){Thread.currentThread().interrupt();throw new AssertionError(error);}}
    private UUID post(UUID material,String type,String quantity,UUID source){return post(UUID.randomUUID(),material,type,quantity,source,false);}
    private UUID post(UUID event,UUID material,String type,String quantity,UUID source,boolean historical){
        UUID id=UUID.randomUUID();db.update("INSERT INTO production_material_stock_postings(id,event_id,demand_id,posting_type,qty_base,source_posting_id,ledger_order) VALUES(?,?,?,?,?,?,"+(historical?"NULL":"DEFAULT")+")",id,event,material,type,new BigDecimal(quantity),source);return id;
    }
    private UUID report(int status,String quantity){
        UUID report=UUID.randomUUID();db.update("INSERT INTO production_daily_reports(id,status) VALUES(?,?)",report,status);
        db.update("INSERT INTO production_daily_report_items(id,report_id,execution_segment_id,qty) VALUES(?,?,?,?)",UUID.randomUUID(),report,segment,new BigDecimal(quantity));return report;
    }
    private BigDecimal room(UUID excluded){return db.queryForObject("SELECT fn_execution_partial_material_report_room(?,?)",BigDecimal.class,segment,excluded);}
    private static void amount(String expected,BigDecimal actual){assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+" but got "+actual);}
}
