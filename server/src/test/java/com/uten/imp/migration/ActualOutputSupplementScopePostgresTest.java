package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.*;
import java.util.List;
import java.util.Map;
import java.util.LinkedHashMap;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Applied V700 -> V705 upgrade and isolated provenance/cost-family oracles. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class ActualOutputSupplementScopePostgresTest {
    static final PostgreSQLContainer<?> POSTGRES=new PostgreSQLContainer<>("postgres:16-alpine");
    Connection db;
    UUID source,target,sourcePlan,targetPlan,sourceItem,targetItem,goods,unit,workshop,proof,demand,issue;
    @BeforeAll static void migrate() {
        POSTGRES.start();migration("700").migrate();
        assertEquals(1,migration("701").migrate().migrationsExecuted);
        assertEquals(4,migration("705").migrate().migrationsExecuted);
        assertEquals(0,migration("705").migrate().migrationsExecuted);
    }
    static Flyway migration(String version) {
        return Flyway.configure().dataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword())
                .locations("classpath:db/migration").target(version).load();
    }
    @AfterAll static void stop(){POSTGRES.stop();}
    @AfterEach void close()throws Exception{db.close();}
    @BeforeEach void fixture()throws Exception{
        db=DriverManager.getConnection(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());
        String schema="supp_scope_"+UUID.randomUUID().toString().replace("-","");
        sql("CREATE SCHEMA "+schema);sql("SET search_path TO "+schema+",public");
        for(String table:List.of("production_execution_segments","production_execution_segment_splits",
                "production_planning_packages","production_plans","production_plan_items",
                "production_actual_output_supplement_proofs","production_actual_output_supplement_reversals",
                "production_daily_reports","production_daily_report_items","execution_segment_sales_allocations",
                "production_material_demands","production_material_stock_postings","production_material_stock_events",
                "production_material_settlement_postings","production_material_settlement_events",
                "production_material_return_request_items","production_material_return_requests","production_material_return_request_cancellations",
                "production_planning_package_documents","production_planning_package_document_items",
                "stock_documents","stock_document_items","stock_reservations")) {
            com.uten.imp.support.MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(db,table);
        }
        for(String function:List.of("fn_production_material_usage_source_segments(uuid)",
                "fn_production_execution_cost_scope(uuid)","fn_production_execution_cost_members(uuid)",
                "fn_production_execution_cost_target(uuid)","fn_execution_actual_surplus_qty(uuid,boolean)",
                "fn_material_issue_unsettled(uuid)","fn_material_issue_pending_return(uuid,uuid)",
                "fn_material_issue_available(uuid,uuid)","fn_execution_material_custody_valid(uuid)",
                "fn_actual_supplement_increment_identity(uuid)","fn_actual_supplement_material_prepared(uuid)",
                "fn_actual_supplement_material_ready(uuid)","fn_actual_supplement_material_cleared(uuid)",
                "fn_assert_actual_supplement_segment_integrity(uuid)","fn_guard_execution_segment_requirement_shape()")){
            String definition=value("SELECT pg_get_functiondef(CAST(? AS regprocedure))","public."+function).toString();
            sql(definition.replace("FUNCTION public.","FUNCTION "+schema+"."));
        }
        // Source BOM capacity is an independent already-issued material oracle;
        // full execution E2E proves its real calculation and normal START guard.
        sql("CREATE FUNCTION fn_execution_material_output_capacity(UUID,BOOLEAN DEFAULT TRUE) RETURNS NUMERIC LANGUAGE sql STABLE AS 'SELECT 100::numeric'");
        source=UUID.randomUUID();target=UUID.randomUUID();sourcePlan=UUID.randomUUID();targetPlan=UUID.randomUUID();
        sourceItem=UUID.randomUUID();targetItem=UUID.randomUUID();goods=UUID.randomUUID();unit=UUID.randomUUID();workshop=UUID.randomUUID();
        segment(source,sourcePlan,sourceItem,"100","IN_PROGRESS");segment(target,targetPlan,targetItem,"30","READY");
        proof=proof(source,target,targetPlan,targetItem,"30");
        demand=UUID.randomUUID();issue=UUID.randomUUID();
        sql("INSERT INTO production_material_demands(id,execution_segment_id,plan_id,is_deleted,status) VALUES(?,?,?,FALSE,'ISSUED')",demand,source,sourcePlan);
        sql("INSERT INTO production_material_stock_postings(id,demand_id,posting_type,qty_base) VALUES(?,?,'ISSUE',100)",issue,demand);
    }

    @Test void distinctPlanKeepsOneMaterialSourceAndOneCostFamilyWithoutDuplicateDemands()throws Exception{
        assertEquals(source,value("SELECT segment_id FROM fn_production_material_usage_source_segments(?)",target));
        assertEquals(source,value("SELECT fn_production_execution_cost_scope(?)",target));
        assertEquals(2L,value("SELECT count(*) FROM fn_production_execution_cost_members(?)",source));
        amount("130",value("SELECT fn_production_execution_cost_target(?)",source));
        assertEquals(Boolean.TRUE,value("SELECT fn_actual_supplement_material_ready(?)",target));
        sql("SELECT fn_assert_actual_supplement_segment_integrity(?)",target);
        assertEquals(0L,value("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",target));
        assertEquals(0L,value("SELECT count(*) FROM production_planning_package_documents WHERE execution_segment_id=?",target));
    }

    @Test void siblingSupplementsDoNotRecursivelyEvaluateEachOtherWhenReadingOriginalCapacity()throws Exception{
        String schema=value("SELECT current_schema()").toString();
        String definition=value("SELECT pg_get_functiondef('public.fn_execution_material_output_capacity(uuid,boolean)'::regprocedure)").toString();
        sql(definition.replace("FUNCTION public.","FUNCTION "+schema+"."));
        sql("UPDATE production_material_demands SET required_qty=100,per_product_qty=1,requirement_mode='LINEAR',consumption_snapshot=NULL WHERE id=?",demand);
        UUID sibling=UUID.randomUUID(),siblingPlan=UUID.randomUUID(),siblingItem=UUID.randomUUID();
        segment(sibling,siblingPlan,siblingItem,"20","READY");proof(source,sibling,siblingPlan,siblingItem,"20");
        amount("100",value("SELECT fn_execution_material_output_capacity(?,TRUE)",source));
        amount("30",value("SELECT fn_execution_material_output_capacity(?,TRUE)",target));
        amount("20",value("SELECT fn_execution_material_output_capacity(?,TRUE)",sibling));
        assertEquals(Boolean.TRUE,value("SELECT fn_actual_supplement_material_ready(?)",target));
        assertEquals(Boolean.FALSE,value("SELECT fn_actual_supplement_material_ready(?)",source));
    }

    @Test void unrelatedOrForgedTargetCannotBorrowTheOriginalPhysicalCustody()throws Exception{
        UUID unrelated=UUID.randomUUID();segment(unrelated,UUID.randomUUID(),UUID.randomUUID(),"30","WAITING");
        assertEquals(Boolean.FALSE,value("SELECT fn_actual_supplement_material_ready(?)",unrelated));
        assertEquals(0L,value("SELECT count(*) FROM fn_production_material_usage_source_segments(?)",unrelated));
        sql("UPDATE production_execution_segments SET product_goods_id=? WHERE id=?",UUID.randomUUID(),target);
        assertEquals(Boolean.FALSE,value("SELECT fn_actual_supplement_material_ready(?)",target));
        assertEquals("actual_supplement_segment_identity_guard",assertThrows(PSQLException.class,
                ()->sql("SELECT fn_assert_actual_supplement_segment_integrity(?)",target)).getServerErrorMessage().getConstraint());
    }

    @Test void previouslyConsumedIssueCannotStartANewBatchButThisOwnApprovedConsumptionRemainsValid()throws Exception{
        UUID event=UUID.randomUUID(),posting=UUID.randomUUID();
        sql("INSERT INTO production_material_settlement_events(id,event_type) VALUES(?,'POST')",event);
        sql("INSERT INTO production_material_settlement_postings(id,event_id,demand_id,issue_posting_id,settlement_type,qty_base) VALUES(?,?,?,?,'CONSUMED',100)",posting,event,demand,issue);
        amount("0",value("SELECT fn_material_issue_available(?,NULL)",issue));
        assertEquals(Boolean.FALSE,value("SELECT fn_actual_supplement_material_ready(?)",target));
        UUID report=UUID.randomUUID();
        sql("INSERT INTO production_daily_reports(id,status,is_deleted) VALUES(?,1,FALSE)",report);
        sql("INSERT INTO production_daily_report_items(id,report_id,execution_segment_id,qty,is_deleted) VALUES(?,?,?,30,FALSE)",UUID.randomUUID(),report,target);
        sql("UPDATE production_material_settlement_events SET daily_report_id=? WHERE id=?",report,event);
        assertEquals(Boolean.TRUE,value("SELECT fn_actual_supplement_material_ready(?)",target));
    }

    @Test void cancellationRemovesFutureCapacityButPreservesHistoricalCostSource()throws Exception{
        sql("INSERT INTO production_actual_output_supplement_reversals(id,proof_id) VALUES(?,?)",UUID.randomUUID(),proof);
        assertEquals(Boolean.FALSE,value("SELECT fn_actual_supplement_material_ready(?)",target));
        assertEquals(0L,value("SELECT count(*) FROM fn_production_material_usage_source_segments(?)",target));
        assertEquals(source,value("SELECT fn_production_execution_cost_scope(?)",target));
        amount("100",value("SELECT fn_production_execution_cost_target(?)",source));
    }

    @Test void provenNestedSupplementAndPriorToleratedOutputAreCountedExactlyOnce()throws Exception{
        UUID next=UUID.randomUUID(),plan=UUID.randomUUID(),item=UUID.randomUUID();
        segment(next,plan,item,"20","READY");proof(target,next,plan,item,"20");
        assertEquals(source,value("SELECT fn_production_execution_cost_scope(?)",next));
        assertEquals(3L,value("SELECT count(*) FROM fn_production_execution_cost_members(?)",source));
        amount("150",value("SELECT fn_production_execution_cost_target(?)",source));
        UUID report=UUID.randomUUID();sql("INSERT INTO production_daily_reports(id,status,is_deleted) VALUES(?,1,FALSE)",report);
        sql("INSERT INTO production_daily_report_items(id,report_id,execution_segment_id,qty,is_actual_surplus,is_deleted) VALUES(?,?,?,5,TRUE,FALSE)",UUID.randomUUID(),report,source);
        amount("155",value("SELECT fn_production_execution_cost_target(?)",source));
    }

    @Test void additionalPlanFootprintIncludesTheOriginalMaterialBeforeInventoryLocks()throws Exception{
        UUID raw=UUID.randomUUID();sql("UPDATE production_material_demands SET goods_id=? WHERE id=?",raw,demand);
        var jdbc=new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(
                new org.springframework.jdbc.datasource.SingleConnectionDataSource(db,true));
        var em=org.mockito.Mockito.mock(jakarta.persistence.EntityManager.class);
        org.mockito.Mockito.when(em.createNativeQuery(org.mockito.ArgumentMatchers.anyString())).thenAnswer(call->{
            String statement=call.getArgument(0);Map<String,Object> parameters=new LinkedHashMap<>();
            var query=org.mockito.Mockito.mock(jakarta.persistence.Query.class);
            org.mockito.Mockito.when(query.setParameter(org.mockito.ArgumentMatchers.anyString(),org.mockito.ArgumentMatchers.any())).thenAnswer(bind->{
                parameters.put(bind.getArgument(0),bind.getArgument(1));return query;
            });
            org.mockito.Mockito.when(query.getResultList()).thenAnswer(read->jdbc.query(statement,parameters,(row,index)->{
                int columns=row.getMetaData().getColumnCount();if(columns==1)return row.getObject(1);
                Object[] values=new Object[columns];for(int i=0;i<columns;i++)values[i]=row.getObject(i+1);return values;
            }));return query;
        });
        var service=new com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService(em,
                org.mockito.Mockito.mock(com.uten.imp.application.concurrency.FulfillmentMutationLocks.class),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));
        var footprint=service.discover(targetPlan,List.of());
        assertTrue(footprint.inventoryDimensions().contains(new com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension(raw,null)));
    }

    @Test void closedZeroMaterialSourceRetainsOnlyItsExactFrozenExceptionAcrossTheNewPlan()throws Exception{
        UUID analysis=UUID.randomUUID();
        sql("DELETE FROM production_material_stock_postings");sql("DELETE FROM production_material_demands");
        sql("UPDATE production_execution_segments SET material_requirement_mode='ZERO_MATERIAL',zero_material_reason='DIRECT_MAKE',zero_material_analysis_id=?,status='COMPLETED' WHERE id=?",analysis,source);
        sql("UPDATE production_plans SET material_analysis_id=?,is_closed=TRUE WHERE id=?",analysis,sourcePlan);
        sql("DELETE FROM production_execution_segments WHERE id=?",target);
        sql("CREATE TRIGGER zero_evidence BEFORE INSERT ON production_execution_segments FOR EACH ROW EXECUTE FUNCTION fn_guard_execution_segment_requirement_shape()");
        insertInheritedZero(target,analysis);
        assertEquals(Boolean.TRUE,value("SELECT fn_actual_supplement_material_ready(?)",target));
        assertEquals(Boolean.TRUE,value("SELECT fn_actual_supplement_material_cleared(?)",target));
        sql("SELECT fn_assert_actual_supplement_segment_integrity(?)",target);
        PSQLException failure=assertThrows(PSQLException.class,()->insertInheritedZero(UUID.randomUUID(),analysis));
        assertEquals("production_execution_segment_zero_evidence_guard",failure.getServerErrorMessage().getConstraint());
    }

    private void insertInheritedZero(UUID id,UUID analysis)throws Exception{
        sql("""
                INSERT INTO production_execution_segments(id,plan_id,source_plan_item_id,package_id,planned_qty,status,
                    product_goods_id,product_unit_id,product_unit_rate,bom_fingerprint,workshop_department_id,
                    material_requirement_mode,zero_material_reason,zero_material_analysis_id,is_deleted)
                SELECT ?,?,?,package.id,30,'READY',?,?,1,?,?,'ZERO_MATERIAL','DIRECT_MAKE',?,FALSE
                FROM production_planning_packages package WHERE package.plan_id=?
                """,id,targetPlan,targetItem,goods,unit,"a".repeat(64),workshop,analysis,targetPlan);
    }

    private void segment(UUID id,UUID plan,UUID item,String qty,String status)throws Exception{
        UUID pack=UUID.randomUUID();
        sql("INSERT INTO production_plans(id,status,is_deleted,is_canceled,is_stopped,is_closed) VALUES(?,1,FALSE,FALSE,FALSE,FALSE)",plan);
        sql("INSERT INTO production_plan_items(id,plan_id,qty,is_deleted) VALUES(?,?,?,FALSE)",item,plan,new BigDecimal(qty));
        sql("INSERT INTO production_planning_packages(id,plan_id,status,is_deleted) VALUES(?,?,'CONFIRMED',FALSE)",pack,plan);
        sql("""
                INSERT INTO production_execution_segments(id,plan_id,source_plan_item_id,package_id,planned_qty,status,
                    product_goods_id,product_unit_id,product_unit_rate,bom_fingerprint,workshop_department_id,material_requirement_mode,is_deleted)
                VALUES(?,?,?,?,?,?,?, ?,1,?,?,'DEMANDED',FALSE)
                """,id,plan,item,pack,new BigDecimal(qty),status,goods,unit,"a".repeat(64),workshop);
    }
    private UUID proof(UUID original,UUID added,UUID plan,UUID item,String qty)throws Exception{
        UUID id=UUID.randomUUID();
        sql("""
                INSERT INTO production_actual_output_supplement_proofs(id,source_execution_segment_id,supplement_execution_segment_id,
                    supplement_plan_id,supplement_plan_item_id,supplement_qty) VALUES(?,?,?,?,?,?)
                """,id,original,added,plan,item,new BigDecimal(qty));return id;
    }
    private Object value(String query,Object...args)throws Exception{
        try(PreparedStatement s=db.prepareStatement(query)){bind(s,args);try(ResultSet r=s.executeQuery()){assertTrue(r.next());return r.getObject(1);}}
    }
    private void sql(String query,Object...args)throws Exception{try(PreparedStatement s=db.prepareStatement(query)){bind(s,args);s.execute();}}
    private static void bind(PreparedStatement s,Object[]args)throws Exception{for(int i=0;i<args.length;i++)s.setObject(i+1,args[i]);}
    private static void amount(String expected,Object actual){assertEquals(0,new BigDecimal(expected).compareTo((BigDecimal)actual));}
}
