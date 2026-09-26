package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.testcontainers.containers.PostgreSQLContainer;
import java.sql.*;
import java.util.List;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

/** Forward upgrade and real deferred constraints, independent of application guards. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ActualProductionOutputMigrationPostgresTest {
    static final PostgreSQLContainer<?> DATABASE=new PostgreSQLContainer<>("postgres:16-alpine");
    Connection db;
    UUID segment,planItem,goods,unit,sales,allocation;
    @BeforeAll static void migrate() {
        DATABASE.start(); migration("693").migrate();
        assertEquals(1,migration("694").migrate().migrationsExecuted);
        assertEquals(0,migration("694").migrate().migrationsExecuted);
    }
    static Flyway migration(String target){return Flyway.configure().dataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword())
            .locations("classpath:db/migration").target(target).load();}
    @AfterAll static void stop(){DATABASE.stop();}
    @AfterEach void close()throws Exception{db.close();}
    @BeforeEach void fixture()throws Exception{
        db=DriverManager.getConnection(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword());
        String schema="actual_"+UUID.randomUUID().toString().replace("-","");
        sql("CREATE SCHEMA "+schema);sql("SET search_path TO "+schema+",public");
        for(String table:List.of("production_execution_segments","execution_segment_sales_allocations","production_daily_reports",
                "production_daily_report_items","stock_documents","stock_document_items","production_planning_packages",
                "production_plans","production_material_analysis_plan_links","plan_order_item_links"))
            com.uten.imp.support.MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(db,table);
        for(String function:List.of("fn_execution_actual_surplus_qty(uuid,boolean)","fn_plan_actual_surplus_qty(uuid,boolean)",
                "fn_daily_report_is_public_output(uuid)","fn_validate_daily_report_execution_segment()",
                "fn_guard_daily_report_output_identity()","fn_assert_daily_report_output_batch()",
                "fn_assert_actual_report_material_posting(uuid)","fn_check_actual_report_material_posting()",
                "fn_assert_execution_segment_public_surplus_capacity(uuid)","fn_assert_execution_segment_public_surplus_row()",
                "fn_assert_daily_report_segment_public_status()")) {
            String definition=scalar("SELECT pg_get_functiondef(CAST(? AS regprocedure))","public."+function);
            sql(definition.replace("FUNCTION public.","FUNCTION "+schema+"."));
        }
        try(Statement statement=db.createStatement();ResultSet rows=statement.executeQuery("""
                SELECT pg_get_triggerdef(t.oid) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
                JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal
                AND t.tgname IN('trg_assert_daily_report_segment_public_fact','trg_assert_daily_report_segment_public_status',
                    'trg_validate_daily_report_execution_segment','trg_guard_daily_report_output_identity','trg_assert_daily_report_output_batch',
                    'trg_assert_actual_report_material_posting','trg_assert_actual_report_item_material_posting')
                """)){
            while(rows.next())sql(rows.getString(1).replace(" ON public."," ON "+schema+".")
                    .replace("FUNCTION public.","FUNCTION "+schema+"."));
        }
        sql("ALTER TABLE production_daily_report_items ADD CONSTRAINT daily_report_output_slice_shape "+
                scalar("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname='daily_report_output_slice_shape' AND conrelid='public.production_daily_report_items'::regclass"));
        segment=UUID.randomUUID();planItem=UUID.randomUUID();goods=UUID.randomUUID();unit=UUID.randomUUID();sales=UUID.randomUUID();allocation=UUID.randomUUID();
        sql("INSERT INTO production_execution_segments(id,source_plan_item_id,product_goods_id,product_unit_id,planned_qty,is_deleted,status) VALUES(?,?,?,?,100,false,'IN_PROGRESS')",segment,planItem,goods,unit);
        sql("INSERT INTO execution_segment_sales_allocations(id,execution_segment_id,sales_order_item_id,allocated_qty) VALUES(?,?,?,100)",allocation,segment,sales);
    }
    @Test void separatelyApprovedActualOutputDoesNotExpandSalesOrPlan()throws Exception{
        report(100,false,1,100);
        UUID surplus=report(40,true,0,40);
        assertEquals("0",scalar("SELECT fn_execution_actual_surplus_qty(?,false)",segment));
        assertEquals(0,new java.math.BigDecimal(scalar("SELECT fn_execution_actual_surplus_qty(?,true)",segment)).compareTo(new java.math.BigDecimal("40")));
        sql("UPDATE production_daily_reports SET status=1 WHERE id=?",surplus);
        assertEquals(0,new java.math.BigDecimal(scalar("SELECT fn_execution_actual_surplus_qty(?,false)",segment)).compareTo(new java.math.BigDecimal("40")));
        assertEquals(0,new java.math.BigDecimal(scalar("SELECT planned_qty FROM production_execution_segments WHERE id=?",segment)).compareTo(new java.math.BigDecimal("100")));
        assertEquals(0,new java.math.BigDecimal(scalar("SELECT allocated_qty FROM execution_segment_sales_allocations WHERE id=?",allocation)).compareTo(new java.math.BigDecimal("100")));
        sql("UPDATE production_daily_reports SET status=-1 WHERE id=?",surplus);
        assertEquals("0",scalar("SELECT fn_execution_actual_surplus_qty(?,false)",segment));
    }
    @Test void outputBatchCannotLoseOrDuplicatePartOfEnteredPhysicalQuantity()throws Exception{
        PSQLException error=assertThrows(PSQLException.class,()->report(40,true,0,41));
        assertEquals("daily_report_output_batch_conservation",error.getServerErrorMessage().getConstraint());
    }
    @Test void publicOutputCannotBorrowSalesOwnershipOrWorkshopDestination()throws Exception{
        UUID report=report(40,true,0,40);
        assertThrows(PSQLException.class,()->sql("UPDATE production_daily_report_items SET sales_order_item_id=? WHERE report_id=?",sales,report));
        assertThrows(PSQLException.class,()->sql("UPDATE production_daily_report_items SET destination='WORKSHOP',direct_transfer_demand_id=? WHERE report_id=?",UUID.randomUUID(),report));
    }
    @Test void batchQuantityCannotBeNullAndApprovedOwnershipCannotBeEdited()throws Exception{
        UUID report=report(40,true,0,40);
        assertThrows(PSQLException.class,()->sql("UPDATE production_daily_report_items SET output_batch_qty=NULL WHERE report_id=?",report));
        assertThrows(PSQLException.class,()->sql("UPDATE production_daily_report_items SET qty=NULL WHERE report_id=?",report));
        sql("UPDATE production_daily_reports SET status=1 WHERE id=?",report);
        assertThrows(PSQLException.class,()->sql("UPDATE production_daily_report_items SET is_actual_surplus=false WHERE report_id=?",report));
    }
    @Test void twoDraftsStillCannotAllocateTheSameOriginalSalesQuantity()throws Exception{
        report(70,false,0,70);
        PSQLException error=assertThrows(PSQLException.class,()->report(31,false,0,31));
        assertEquals("daily_report_segment_planned_capacity_guard",error.getServerErrorMessage().getConstraint());
    }
    @Test void insertingIntoAnAlreadyApprovedReportCannotBypassActualMaterialPosting()throws Exception{
        sql("UPDATE production_execution_segments SET material_requirement_mode='DEMANDED' WHERE id=?",segment);
        PSQLException error=assertThrows(PSQLException.class,()->report(40,true,1,40));
        assertEquals("daily_report_actual_material_posting_guard",error.getServerErrorMessage().getConstraint());
    }
    @Test void historicalLaterPublicBatchRetainsApprovedPlanSurplusIdentityWithoutLocalSalesAllocation()throws Exception{
        UUID plan=UUID.randomUUID(),analysis=UUID.randomUUID(),analysisItem=UUID.randomUUID(),later=UUID.randomUUID();
        sql("INSERT INTO production_plans(id,material_analysis_id,material_analysis_item_id,is_deleted) VALUES(?,?,?,false)",plan,analysis,analysisItem);
        sql("INSERT INTO production_material_analysis_plan_links(plan_id,analysis_id,analysis_item_id,allocation_status,submitted_qty,public_surplus_qty) VALUES(?,?,?,'APPROVED',100,100)",plan,analysis,analysisItem);
        sql("INSERT INTO plan_order_item_links(id,plan_item_id,order_item_id,is_deleted) VALUES(?,?,?,false)",UUID.randomUUID(),planItem,sales);
        sql("INSERT INTO production_execution_segments(id,plan_id,source_plan_item_id,product_goods_id,product_unit_id,planned_qty,is_deleted,status) VALUES(?,?,?,?,?,100,false,'IN_PROGRESS')",later,plan,planItem,goods,unit);
        UUID report=UUID.randomUUID(),item=UUID.randomUUID();
        sql("INSERT INTO production_daily_reports(id,status,is_deleted) VALUES(?,1,false)",report);
        sql("""
                INSERT INTO production_daily_report_items(id,report_id,plan_item_id,goods_id,unit_id,execution_segment_id,
                    qty,is_deleted,is_final,destination,is_public_output,is_actual_surplus)
                VALUES(?,?,?,?,?,?,40,false,false,'WAREHOUSE',false,false)
                """,item,report,planItem,goods,unit,later);
        assertEquals("t",scalar("SELECT fn_daily_report_is_public_output(?)",item));
        sql("UPDATE production_material_analysis_plan_links SET public_surplus_qty=0 WHERE plan_id=?",plan);
        assertEquals("f",scalar("SELECT fn_daily_report_is_public_output(?)",item),"a NULL sales UUID alone must not make internal MAKE demand public");
    }
    UUID report(int qty,boolean actual,int status,int batchQty)throws Exception{
        UUID report=UUID.randomUUID();sql("INSERT INTO production_daily_reports(id,status,is_deleted) VALUES(?,?,false)",report,status);
        sql("""
                INSERT INTO production_daily_report_items(id,report_id,plan_item_id,goods_id,unit_id,execution_segment_id,
                    execution_segment_sales_allocation_id,sales_order_item_id,qty,is_deleted,is_final,destination,
                    output_batch_id,output_batch_qty,is_public_output,is_actual_surplus)
                VALUES(?,?,?,?,?,?,?,?,?,false,false,'WAREHOUSE',?,?,?,?)
                """,UUID.randomUUID(),report,planItem,goods,unit,segment,actual?null:allocation,actual?null:sales,qty,
                UUID.randomUUID(),batchQty,actual,actual);
        return report;
    }
    void sql(String text,Object...args)throws SQLException{
        try(PreparedStatement statement=db.prepareStatement(text)){for(int i=0;i<args.length;i++)statement.setObject(i+1,args[i]);statement.execute();}
    }
    String scalar(String text,Object...args)throws SQLException{
        try(PreparedStatement statement=db.prepareStatement(text)){for(int i=0;i<args.length;i++)statement.setObject(i+1,args[i]);
            try(ResultSet rows=statement.executeQuery()){rows.next();return rows.getString(1);}}
    }
}
