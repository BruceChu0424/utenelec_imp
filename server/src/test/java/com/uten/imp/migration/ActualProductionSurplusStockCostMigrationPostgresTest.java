package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.*;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real forward migration and database backstops; full report/FQC workflow is covered by E2E. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class ActualProductionSurplusStockCostMigrationPostgresTest {
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    Connection db;
    UUID segment, planItem, goods, unit;

    @BeforeAll static void migrate() {
        POSTGRES.start();
        migration("694").migrate();
        assertEquals(1, migration("695").migrate().migrationsExecuted);
        assertEquals(0, migration("695").migrate().migrationsExecuted);
        migration("697").migrate();
        assertEquals(0, migration("697").migrate().migrationsExecuted);
    }
    static Flyway migration(String version) {
        return Flyway.configure().dataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword())
                .locations("classpath:db/migration").target(version).load();
    }
    @AfterAll static void stop() { POSTGRES.stop(); }
    @AfterEach void close() throws Exception { db.close(); }

    @BeforeEach void fixture() throws Exception {
        db=DriverManager.getConnection(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());
        String schema="actual_stock_"+UUID.randomUUID().toString().replace("-","");
        sql("CREATE SCHEMA "+schema);
        sql("SET search_path TO "+schema+",public");
        for (String table:List.of("production_execution_segments","production_execution_segment_splits",
                "execution_segment_sales_allocations","production_planning_packages","production_plan_items",
                "production_plans","goods",
                "production_daily_reports","production_daily_report_items","stock_document_items","stock_documents",
                "preplan_analysis_stock_exact_pegs","production_material_make_receipt_allocations",
                "production_finished_arrival_registrations","production_finished_arrival_registration_items")) {
            sql("CREATE TABLE "+schema+"."+table+" AS SELECT * FROM public."+table+" WITH NO DATA");
        }
        for (String function:List.of("fn_execution_actual_surplus_qty(uuid,boolean)",
                "fn_plan_actual_surplus_qty(uuid,boolean)","fn_production_execution_cost_scope(uuid)",
                "fn_daily_report_is_public_output(uuid)",
                "fn_finished_in_is_public_output(uuid)","fn_production_execution_cost_target(uuid)",
                "fn_guard_plan_actual_inbound_quantity()","fn_validate_finished_in_execution_segment()",
                "fn_guard_execution_segment_finished_in()","fn_guard_public_output_inherited_peg()",
                "fn_reconcile_execution_segment_completion(uuid)","fn_reconcile_execution_completion_report_change()",
                "fn_guard_finished_arrival_explicit_count()","fn_finished_arrival_count_is_proven(uuid)")) {
            String definition=value("SELECT pg_get_functiondef(CAST(? AS regprocedure))","public."+function).toString();
            sql(definition.replace("FUNCTION public.","FUNCTION "+schema+"."));
        }
        sql("CREATE TRIGGER plan_inbound BEFORE INSERT OR UPDATE OF iqty ON production_plan_items FOR EACH ROW EXECUTE FUNCTION fn_guard_plan_actual_inbound_quantity()");
        sql("CREATE TRIGGER inherited_make BEFORE INSERT ON production_material_make_receipt_allocations FOR EACH ROW EXECUTE FUNCTION fn_guard_public_output_inherited_peg()");
        sql("CREATE TRIGGER inherited_analysis BEFORE INSERT ON preplan_analysis_stock_exact_pegs FOR EACH ROW EXECUTE FUNCTION fn_guard_public_output_inherited_peg()");
        segment=UUID.randomUUID(); planItem=UUID.randomUUID(); goods=UUID.randomUUID(); unit=UUID.randomUUID();
        sql("""
                INSERT INTO production_execution_segments(id,source_plan_item_id,product_goods_id,product_unit_id,
                    product_unit_rate,planned_qty,status,is_deleted)
                VALUES(?,?,?,?,2,100,'IN_PROGRESS',FALSE)
                """,segment,planItem,goods,unit);
        sql("INSERT INTO production_plan_items(id,qty,fqty,iqty,is_deleted) VALUES(?,100,0,0,FALSE)",planItem);
    }

    @Test void actualOutputChangesCostBasisWithoutChangingFrozenPlanOrCountingRecoveryTwice() throws Exception {
        UUID approved=report("30",1,true,false);
        report("50",0,true,false);
        report("30",1,true,true);
        report("20",1,false,false);
        amount("260",value("SELECT fn_production_execution_cost_target(?)",segment));
        amount("30",value("SELECT fn_plan_actual_surplus_qty(?,FALSE)",planItem));
        amount("100",value("SELECT planned_qty FROM production_execution_segments WHERE id=?",segment));
        sql("UPDATE production_daily_reports SET status=-1 WHERE id=(SELECT report_id FROM production_daily_report_items WHERE id=?)",approved);
        amount("200",value("SELECT fn_production_execution_cost_target(?)",segment));
    }

    @Test void actualInboundMustFitBothApprovedActualQuantityAndApprovedReportTotal() throws Exception {
        report("30",1,true,false);
        sql("UPDATE production_plan_items SET fqty=130 WHERE id=?",planItem);
        sql("UPDATE production_plan_items SET iqty=130 WHERE id=?",planItem);
        rejected("production_plan_actual_inbound_guard",()->sql("UPDATE production_plan_items SET iqty=131 WHERE id=?",planItem));
        sql("UPDATE production_plan_items SET iqty=0,fqty=20 WHERE id=?",planItem);
        rejected("production_plan_actual_inbound_guard",()->sql("UPDATE production_plan_items SET iqty=21 WHERE id=?",planItem));
        sql("UPDATE production_plan_items SET iqty=20 WHERE id=?",planItem);
    }

    @Test void splitFamilyAddsActualSurplusOnceWithoutRecountingTheRetiredParent() throws Exception {
        UUID root=segment, first=UUID.randomUUID(), remaining=UUID.randomUUID();
        sql("INSERT INTO production_execution_segment_splits(source_segment_id,batch_segment_id,remaining_segment_id) VALUES(?,?,?)",root,first,remaining);
        sql("""
                INSERT INTO production_execution_segments(id,source_plan_item_id,product_unit_rate,planned_qty,
                    source_segment_id,split_root_segment_id,is_deleted)
                VALUES(?,?,2,60,?,?,FALSE),(?,?,2,40,?,?,FALSE)
                """,first,planItem,root,root,remaining,planItem,root,root);
        segment=first;
        UUID source=report("10",1,true,false);
        report("10",1,true,true);
        amount("220",value("SELECT fn_production_execution_cost_target(?)",root));
        sql("UPDATE production_daily_reports SET status=-1 WHERE id=(SELECT report_id FROM production_daily_report_items WHERE id=?)",source);
        amount("200",value("SELECT fn_production_execution_cost_target(?)",root));
    }

    @Test void draftSurplusNeverAuthorizesAnInboundIncrease() throws Exception {
        report("30",0,true,false);
        sql("UPDATE production_plan_items SET fqty=130 WHERE id=?",planItem);
        rejected("production_plan_actual_inbound_guard",()->sql("UPDATE production_plan_items SET iqty=101 WHERE id=?",planItem));
    }

    @Test void exactPublicIdentityCannotInheritMakeOrAnalysisObligations() throws Exception {
        UUID source=report("30",1,true,false);
        UUID item=stockLine(source,"30",UUID.randomUUID());
        assertEquals(Boolean.TRUE,value("SELECT fn_finished_in_is_public_output(?)",item));
        rejected("public_output_inherited_peg_guard",()->sql("INSERT INTO production_material_make_receipt_allocations(receipt_item_id) VALUES(?)",item));
        rejected("public_output_inherited_peg_guard",()->sql("INSERT INTO preplan_analysis_stock_exact_pegs(source_stock_document_item_id) VALUES(?)",item));
        UUID normal=stockLine(report("20",1,false,false),"20",UUID.randomUUID());
        assertEquals(Boolean.FALSE,value("SELECT fn_finished_in_is_public_output(?)",normal));
        sql("INSERT INTO production_material_make_receipt_allocations(receipt_item_id) VALUES(?)",normal);
        sql("INSERT INTO preplan_analysis_stock_exact_pegs(source_stock_document_item_id) VALUES(?)",normal);
    }

    @Test void actualSurplusOnFullySalesAllocatedTaskNeedsItsOwnExactSource() throws Exception {
        sql("INSERT INTO execution_segment_sales_allocations(id,execution_segment_id,allocated_qty) VALUES(?,?,100)",UUID.randomUUID(),segment);
        sql("CREATE TRIGGER finished_identity BEFORE INSERT ON stock_document_items FOR EACH ROW EXECUTE FUNCTION fn_validate_finished_in_execution_segment()");
        stockLine(report("30",1,true,false),"30",UUID.randomUUID());
        rejected("finished_in_segment_sales_allocation_required",()->stockLine(report("20",1,false,false),"20",UUID.randomUUID()));
    }

    @Test void executionInboundLimitUsesProvenSurplusAndStillRejectsOneExtraUnit() throws Exception {
        UUID source=report("30",1,true,false);
        sql("CREATE TRIGGER finished_quantity BEFORE UPDATE OF status ON stock_documents FOR EACH ROW EXECUTE FUNCTION fn_guard_execution_segment_finished_in()");
        UUID first=document();
        stockLine(report("100",1,false,false),"100",first);
        stockLine(source,"30",first);
        sql("UPDATE stock_documents SET status=1 WHERE id=?",first);
        UUID second=document(); stockLine(source,"1",second);
        rejected("stock_document_execution_segment_quantity_guard",()->sql("UPDATE stock_documents SET status=1 WHERE id=?",second));
    }

    @Test void pendingSurplusDraftPreventsCompletionAndDeletingItReevaluatesTheRealFacts() throws Exception {
        UUID normal=report("100",1,false,false), pending=report("30",0,true,false);
        UUID document=document();stockLine(normal,"100",document);
        sql("UPDATE stock_documents SET status=1 WHERE id=?",document);
        value("SELECT fn_reconcile_execution_segment_completion(?)",segment);
        assertEquals("IN_PROGRESS",value("SELECT status FROM production_execution_segments WHERE id=?",segment));
        sql("CREATE CONSTRAINT TRIGGER report_completion AFTER UPDATE OF is_deleted ON production_daily_reports DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_reconcile_execution_completion_report_change()");
        sql("UPDATE production_daily_reports SET is_deleted=TRUE WHERE id=(SELECT report_id FROM production_daily_report_items WHERE id=?)",pending);
        assertEquals("COMPLETED",value("SELECT status FROM production_execution_segments WHERE id=?",segment));
    }

    @Test void legacyAutomaticRegistrationRetainsUnknownCountAndNewAutomaticRowsRequireExactCount() throws Exception {
        UUID source=report("30",1,false,false);
        UUID registration=UUID.randomUUID(),legacy=UUID.randomUUID();
        sql("INSERT INTO production_finished_arrival_registrations(id,source_report_id,stock_in_before_inspection) SELECT ?,report_id,TRUE FROM production_daily_report_items WHERE id=?",registration,source);
        sql("INSERT INTO production_finished_arrival_registration_items(id,registration_id,source_report_item_id) VALUES(?,?,?)",legacy,registration,source);
        sql("CREATE TRIGGER counted BEFORE INSERT ON production_finished_arrival_registration_items FOR EACH ROW EXECUTE FUNCTION fn_guard_finished_arrival_explicit_count()");
        assertEquals(Boolean.FALSE,value("SELECT fn_finished_arrival_count_is_proven(?)",legacy));
        assertNull(value("SELECT counted_qty FROM production_finished_arrival_registration_items WHERE id=?",legacy));
        rejected("finished_arrival_explicit_count_guard",()->sql("INSERT INTO production_finished_arrival_registration_items(id,registration_id,source_report_item_id) VALUES(?,?,?)",UUID.randomUUID(),registration,source));
        rejected("finished_arrival_explicit_count_guard",()->sql("INSERT INTO production_finished_arrival_registration_items(id,registration_id,source_report_item_id,counted_qty) VALUES(?,?,?,29)",UUID.randomUUID(),registration,source));
        UUID confirmed=UUID.randomUUID();
        sql("INSERT INTO production_finished_arrival_registration_items(id,registration_id,source_report_item_id,counted_qty) VALUES(?,?,?,30)",confirmed,registration,source);
        assertEquals(Boolean.TRUE,value("SELECT fn_finished_arrival_count_is_proven(?)",confirmed));
        UUID unrelated=report("30",1,false,false);
        rejected("finished_arrival_explicit_count_guard",()->sql("INSERT INTO production_finished_arrival_registration_items(id,registration_id,source_report_item_id,counted_qty) VALUES(?,?,?,30)",UUID.randomUUID(),registration,unrelated));
    }

    @Test void standardRegistrationDoesNotClaimAPhysicalCountBeforeWarehouseAcceptance() throws Exception {
        UUID source=report("30",1,false,false),registration=UUID.randomUUID(),item=UUID.randomUUID();
        sql("INSERT INTO production_finished_arrival_registrations(id,source_report_id,stock_in_before_inspection) SELECT ?,report_id,FALSE FROM production_daily_report_items WHERE id=?",registration,source);
        sql("CREATE TRIGGER counted BEFORE INSERT ON production_finished_arrival_registration_items FOR EACH ROW EXECUTE FUNCTION fn_guard_finished_arrival_explicit_count()");
        sql("INSERT INTO production_finished_arrival_registration_items(id,registration_id,source_report_item_id) VALUES(?,?,?)",item,registration,source);
        assertEquals(Boolean.FALSE,value("SELECT fn_finished_arrival_count_is_proven(?)",item));
    }

    @Test void healthScanAcceptsProvenActualOutputAndStillDetectsMissingProofOrInboundBeyondReport() throws Exception {
        UUID plan=UUID.randomUUID(),source=report("30",1,true,false);
        sql("INSERT INTO production_plans(id,is_deleted) VALUES(?,FALSE)",plan);
        sql("UPDATE production_plan_items SET plan_id=?,goods_id=?,fqty=130,iqty=130 WHERE id=?",plan,goods,planItem);
        String from=org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                com.uten.imp.features.production.chain.ProductionChainHealthService.class,
                "reportOrInboundOverflowFrom","TRUE");
        assertEquals(0L,value("SELECT COUNT(*) "+from));
        sql("UPDATE production_daily_reports SET status=-1 WHERE id=(SELECT report_id FROM production_daily_report_items WHERE id=?)",source);
        report("50",0,true,false);report("30",1,true,true);
        assertEquals(1L,value("SELECT COUNT(*) "+from));
        sql("UPDATE production_daily_reports SET status=1 WHERE id=(SELECT report_id FROM production_daily_report_items WHERE id=?)",source);
        sql("UPDATE production_plan_items SET fqty=129 WHERE id=?",planItem);
        assertEquals(1L,value("SELECT COUNT(*) "+from));
        amount("100",value("SELECT qty FROM production_plan_items WHERE id=?",planItem));
    }

    private UUID report(String quantity,int status,boolean actual,boolean recovery) throws Exception {
        UUID report=UUID.randomUUID(),item=UUID.randomUUID();
        sql("INSERT INTO production_daily_reports(id,status,is_deleted) VALUES(?,?,FALSE)",report,status);
        sql("""
                INSERT INTO production_daily_report_items(id,report_id,execution_segment_id,plan_item_id,goods_id,
                    unit_id,unit_rate,qty,is_deleted,is_actual_surplus,is_public_output,fqc_recovery_authorization_id)
                VALUES(?,?,?,?,?,?,2,?,FALSE,?,?,?)
                """,item,report,segment,planItem,goods,unit,new BigDecimal(quantity),actual,actual,recovery?UUID.randomUUID():null);
        return item;
    }
    private UUID document() throws Exception {
        UUID id=UUID.randomUUID();sql("INSERT INTO stock_documents(id,doc_type,status,is_deleted) VALUES(?,'FINISHED_IN',0,FALSE)",id);return id;
    }
    private UUID stockLine(UUID source,String quantity,UUID document) throws Exception {
        UUID id=UUID.randomUUID();
        sql("""
                INSERT INTO stock_document_items(id,doc_id,bill_type,execution_segment_id,upstream_item_id,source_daily_report_item_id,
                    goods_id,unit_id,unit_rate,qty,is_deleted)
                VALUES(?,?,'FINISHED_IN',?,?,?,?,?,2,?,FALSE)
                """,id,document,segment,planItem,source,goods,unit,new BigDecimal(quantity));return id;
    }
    private Object value(String query,Object... args) throws Exception {
        try(PreparedStatement statement=db.prepareStatement(query)) {bind(statement,args);try(ResultSet rows=statement.executeQuery()){assertTrue(rows.next());return rows.getObject(1);}}
    }
    private void sql(String query,Object... args) throws Exception {
        try(PreparedStatement statement=db.prepareStatement(query)){bind(statement,args);statement.execute();}
    }
    private static void bind(PreparedStatement statement,Object[] args) throws Exception {
        for(int i=0;i<args.length;i++)statement.setObject(i+1,args[i]);
    }
    private static void amount(String expected,Object actual){assertEquals(0,new BigDecimal(expected).compareTo((BigDecimal)actual));}
    private static void rejected(String constraint,org.junit.jupiter.api.function.Executable command){
        PSQLException failure=assertThrows(PSQLException.class,command);
        assertEquals("23514",failure.getSQLState());assertEquals(constraint,failure.getServerErrorMessage().getConstraint());
    }
}
