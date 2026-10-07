package com.uten.imp.migration;

import com.uten.imp.support.MigratedProjectionSchema;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.*;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.*;

import static org.junit.jupiter.api.Assertions.*;

/** Real upgrade plus isolated database authorization oracles; downstream FQC is covered by the business chain. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProductionOverLimitReportPostgresTest {
    static final PostgreSQLContainer<?> POSTGRES=new PostgreSQLContainer<>("postgres:16-alpine");
    Connection db;
    String schema;
    UUID segment,planItem,report,batch;

    @BeforeAll static void migrate() {
        POSTGRES.start();
        migration("820").migrate();
        // V821 belongs to a parallel change and may be present after integration.
        assertTrue(migration("822").migrate().migrationsExecuted>=1);
        assertEquals("822",migration("822").info().current().getVersion().getVersion());
        assertEquals(0,migration("822").migrate().migrationsExecuted);
    }
    static Flyway migration(String target) {
        return Flyway.configure().dataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword())
                .locations("classpath:db/migration").target(target).load();
    }
    @AfterAll static void stop(){POSTGRES.stop();}
    @AfterEach void close()throws Exception{db.close();}
    @BeforeEach void fixture()throws Exception{
        db=connect();schema="over_limit_"+UUID.randomUUID().toString().replace("-","");
        sql(db,"CREATE SCHEMA "+schema);sql(db,"SET search_path TO "+schema+",public");
        for(String table:List.of("production_execution_segments","production_daily_reports","production_daily_report_items",
                "production_actual_output_supplement_requests","production_actual_output_supplement_proofs",
                "production_actual_output_supplement_claims","production_actual_output_supplement_reversals",
                "production_daily_report_target_events","production_fqc_recovery_authorizations")) {
            MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(db,table);
        }
        for(String function:List.of("fn_execution_overproduction_policy_applies(uuid)",
                "fn_actual_supplement_pending_qty(uuid,uuid)","fn_execution_actual_surplus_available(uuid,uuid)",
                "fn_execution_actual_surplus_qty(uuid,boolean)","fn_execution_tolerance_surplus_qty(uuid,boolean)",
                "fn_daily_report_output_authorized(uuid)","fn_guard_report_over_limit_snapshot()",
                "fn_assert_actual_output_policy_limit_for_report(uuid)")) {
            String body=(String)value(db,"SELECT pg_get_functiondef(CAST(? AS regprocedure))","public."+function);
            sql(db,body.replace("FUNCTION public.","FUNCTION "+schema+"."));
        }
        sql(db,"CREATE TRIGGER over_limit_snapshot BEFORE INSERT OR UPDATE ON production_daily_report_items FOR EACH ROW EXECUTE FUNCTION fn_guard_report_over_limit_snapshot()");
        segment=UUID.randomUUID();planItem=UUID.randomUUID();report=UUID.randomUUID();batch=UUID.randomUUID();
        sql(db,"INSERT INTO production_execution_segments(id,source_plan_item_id,planned_qty,allowed_overproduction_rate,overproduction_rate_version,is_deleted) VALUES(?,?,1000,0.10,0,FALSE)",segment,planItem);
        report(db,report);
    }

    @Test void twelveHundredIsRecordedWithoutTurningTheLastHundredIntoAuthorizedStock()throws Exception{
        UUID normal=insert(db,report,"100",false);
        UUID held=insert(db,report,"100",true);
        amount("200",value(db,"SELECT fn_execution_actual_surplus_qty(?,TRUE)",segment));
        amount("100",value(db,"SELECT fn_execution_tolerance_surplus_qty(?,TRUE)",segment));
        amount("0",value(db,"SELECT fn_execution_actual_surplus_available(?)",segment));
        assertEquals(Boolean.TRUE,value(db,"SELECT fn_daily_report_output_authorized(?)",normal));
        assertEquals(Boolean.FALSE,value(db,"SELECT fn_daily_report_output_authorized(?)",held));
        amount("1000",value(db,"SELECT (overproduction_authorization_snapshot->>'plannedQty')::numeric FROM production_daily_report_items WHERE id=?",held));
        sql(db,"SELECT fn_assert_actual_output_policy_limit_for_report(?)",report);
        sql(db,"UPDATE production_daily_reports SET status=1 WHERE id=?",report);
        sql(db,"SELECT fn_assert_actual_output_policy_limit_for_report(?)",report);
        amount("200",value(db,"SELECT fn_execution_actual_surplus_qty(?,FALSE)",segment));
    }

    @Test void cannotSkipUnusedAllowanceOrWriteTheWholeTwoHundredAsOrdinarySurplus()throws Exception{
        assertConstraint("report_over_limit_allowance_split",()->insert(db,report,"200",false));
        assertConstraint("report_over_limit_allowance_split",()->insert(db,report,"200",true));
        insert(db,report,"40",false);
        assertConstraint("report_over_limit_allowance_split",()->insert(db,report,"160",true));
        insert(db,report,"60",false);insert(db,report,"100",true);
        amount("200",value(db,"SELECT fn_execution_actual_surplus_qty(?,TRUE)",segment));
    }

    @Test void ratioChangeCannotWashAwayTheCapturedExceptionOrChangeItsPhysicalCount()throws Exception{
        insert(db,report,"100",false);UUID held=insert(db,report,"100",true);
        sql(db,"UPDATE production_execution_segments SET allowed_overproduction_rate=0.20,overproduction_rate_version=1 WHERE id=?",segment);
        sql(db,"SELECT fn_assert_actual_output_policy_limit_for_report(?)",report);
        assertEquals(Boolean.FALSE,value(db,"SELECT fn_daily_report_output_authorized(?)",held));
        amount("0",value(db,"SELECT fn_execution_actual_surplus_available(?)",segment));
        assertConstraint("report_over_limit_snapshot_identity",()->sql(db,"UPDATE production_daily_report_items SET is_over_limit=FALSE,over_limit_reason=NULL WHERE id=?",held));
        assertConstraint("report_over_limit_snapshot_identity",()->sql(db,"UPDATE production_daily_report_items SET qty=99 WHERE id=?",held));
        assertConstraint("report_over_limit_snapshot_identity",()->sql(db,"UPDATE production_daily_report_items SET overproduction_authorization_snapshot=NULL WHERE id=?",held));
    }

    @Test void reversingReportReleasesCapacityButKeepsTheCapturedBatchEvidence()throws Exception{
        insert(db,report,"100",false);UUID held=insert(db,report,"100",true);
        sql(db,"UPDATE production_daily_reports SET status=-1 WHERE id=?",report);
        amount("100",value(db,"SELECT fn_execution_actual_surplus_available(?)",segment));
        amount("0",value(db,"SELECT fn_execution_actual_surplus_qty(?,TRUE)",segment));
        assertEquals(Boolean.TRUE,value(db,"SELECT overproduction_authorization_snapshot IS NOT NULL FROM production_daily_report_items WHERE id=?",held));
    }

    @Test void legacyUncapturedReportsKeepTheirOldLimitInsteadOfGainingAnException()throws Exception{
        sql(db,"ALTER TABLE production_daily_report_items DISABLE TRIGGER over_limit_snapshot");
        insert(db,report,"200",false);
        sql(db,"ALTER TABLE production_daily_report_items ENABLE TRIGGER over_limit_snapshot");
        assertConstraint("actual_output_effective_rate_limit",()->sql(db,"SELECT fn_assert_actual_output_policy_limit_for_report(?)",report));
    }

    @Test void qualityRecoveryCannotClearTheOriginalOverLimitMarker()throws Exception{
        insert(db,report,"100",false);UUID held=insert(db,report,"100",true);
        UUID recovery=UUID.randomUUID(),replacement=UUID.randomUUID();
        sql(db,"INSERT INTO production_fqc_recovery_authorizations(id,source_report_item_id) VALUES(?,?)",recovery,held);
        String statement="""
                INSERT INTO production_daily_report_items(id,report_id,execution_segment_id,plan_item_id,
                    output_batch_id,output_batch_qty,qty,is_actual_surplus,is_public_output,is_over_limit,
                    over_limit_reason,is_deleted,destination,fqc_recovery_authorization_id)
                VALUES(?,?,?,?,?,10,10,TRUE,TRUE,?,?,FALSE,'WAREHOUSE',?)
                """;
        assertConstraint("report_over_limit_recovery_identity",()->sql(db,statement,replacement,report,segment,planItem,
                UUID.randomUUID(),false,null,recovery));
        sql(db,statement,replacement,report,segment,planItem,UUID.randomUUID(),true,"如实清点产出超限",recovery);
        assertEquals(Boolean.FALSE,value(db,"SELECT fn_daily_report_output_authorized(?)",replacement));
        amount("200",value(db,"SELECT fn_execution_actual_surplus_qty(?,TRUE)",segment));
        assertConstraint("report_over_limit_snapshot_identity",()->sql(db,"UPDATE production_daily_report_items SET is_over_limit=FALSE,over_limit_reason=NULL WHERE id=?",replacement));
    }

    @Test void twoConnectionsCannotBothTakeTheLastHundred()throws Exception{
        UUID other=UUID.randomUUID();report(db,other);
        try(Connection first=connect();Connection second=connect();ExecutorService pool=Executors.newVirtualThreadPerTaskExecutor()) {
            sql(first,"SET search_path TO "+schema+",public");sql(second,"SET search_path TO "+schema+",public");
            first.setAutoCommit(false);second.setAutoCommit(false);
            insert(first,report,"100",false);
            CountDownLatch started=new CountDownLatch(1);
            Future<String> next=pool.submit(()->{
                started.countDown();
                try{insert(second,other,"100",false);second.commit();return "unexpected success";}
                catch(PSQLException failure){second.rollback();return failure.getServerErrorMessage().getConstraint();}
            });
            assertTrue(started.await(5,TimeUnit.SECONDS));first.commit();
            assertEquals("report_over_limit_allowance_split",next.get(15,TimeUnit.SECONDS));
        }
        amount("100",value(db,"SELECT fn_execution_actual_surplus_qty(?,TRUE)",segment));
    }

    private UUID insert(Connection connection,UUID reportId,String qty,boolean held)throws Exception{
        UUID id=UUID.randomUUID();
        sql(connection,"""
                INSERT INTO production_daily_report_items(id,report_id,execution_segment_id,plan_item_id,
                    output_batch_id,output_batch_qty,qty,is_actual_surplus,is_public_output,is_over_limit,
                    over_limit_reason,is_deleted,destination)
                VALUES(?,?,?,?,?,1200,?,TRUE,TRUE,?,?,FALSE,'WAREHOUSE')
                """,id,reportId,segment,planItem,batch,new BigDecimal(qty),held,held?"如实清点产出超限":null);
        return id;
    }
    private static void report(Connection c,UUID id)throws Exception{sql(c,"INSERT INTO production_daily_reports(id,status,is_deleted) VALUES(?,0,FALSE)",id);}
    private static Connection connect()throws Exception{return DriverManager.getConnection(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());}
    private static Object value(Connection c,String query,Object...args)throws Exception{
        try(PreparedStatement s=c.prepareStatement(query)){bind(s,args);try(ResultSet r=s.executeQuery()){assertTrue(r.next());return r.getObject(1);}}
    }
    private static void sql(Connection c,String query,Object...args)throws Exception{try(PreparedStatement s=c.prepareStatement(query)){bind(s,args);s.execute();}}
    private static void bind(PreparedStatement s,Object[]args)throws Exception{for(int i=0;i<args.length;i++)s.setObject(i+1,args[i]);}
    private static void amount(String expected,Object actual){assertEquals(0,new BigDecimal(expected).compareTo((BigDecimal)actual));}
    private static void assertConstraint(String constraint,org.junit.jupiter.api.function.Executable action){
        PSQLException failure=assertThrows(PSQLException.class,action);
        assertEquals(constraint,failure.getServerErrorMessage().getConstraint(),failure.getMessage());
    }
}
