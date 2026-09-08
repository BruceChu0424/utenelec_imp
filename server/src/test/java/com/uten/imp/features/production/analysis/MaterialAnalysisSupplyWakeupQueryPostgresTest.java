package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.support.ProcurementReceiptFixtureSupport;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import jakarta.persistence.Query;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.DriverManager;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/** Real current-schema query equivalence. Source facts commit with every database guard enabled. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class MaterialAnalysisSupplyWakeupQueryPostgresTest {
    private static final PostgreSQLContainer<?> DB=new PostgreSQLContainer<>("postgres:16-alpine");
    private static final AtomicInteger NUMBERS=new AtomicInteger(860000);
    private static JdbcTemplate db;
    private static EntityManagerFactory factory;
    private static EntityManager em;
    private static MaterialAnalysisSupplyWakeupService service;
    private static UUID unit,actor,maker;
    private static String lastSql;
    // Frozen pre-change dimension bodies: whitespace only is normalized. All UNION/legacy conditions stay intact.
    private static final Map<String,String> DIMENSION_HASHES=Map.of(
            "purchaseTargets","38e5b797bed8d0ce7b224a64e12d00cff58b9cd6037ee0788f7c15311806e28b",
            "subcontractTargets","bb2178d63b2bea3526f7a2cc86b2d9f37251feaccbaf538b92e35e0ea04cf53c",
            "inspectionStockInTargets","61591df2103625e84bf6bcebe71eeba318d6f2f29204d582ad6eadc405f452b7",
            "finishedInboundTargets","ece962f5860f6ea330ea7b4d85a98e33e2dcb52c7b65211766eecab89f5d5dca");
    // Independent, pre-change selector. This is intentionally not constructed from the new candidate filter.
    private static final String OLD_SELECTOR="""
            SELECT analysis.id, analysis.maker_id
            FROM production_material_analyses analysis
            WHERE analysis.is_deleted = FALSE
              AND (analysis.status IN ('ACTIVE','PARTIALLY_PLANNED')
                OR analysis.status='COMPLETED'
                  AND fn_material_analysis_fulfillment_status(analysis.id)<>'COMPLETED')
              AND analysis.warehouse_id IS NOT NULL
              AND EXISTS (
                  SELECT 1 FROM production_material_analysis_materials material
                  JOIN dimensions dimension
                    ON fn_warehouse_same_main(dimension.warehouse_id,analysis.warehouse_id)
                   AND dimension.goods_id = material.goods_id
                   AND dimension.color_id IS NOT DISTINCT FROM material.color_id
                  WHERE material.analysis_id = analysis.id AND material.active = TRUE)
            ORDER BY analysis.id
            """;

    @BeforeAll static void start() throws Exception {
        DB.start();
        Flyway.configure().dataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword())
                .locations("classpath:db/migration").target("531").load().migrate();
        var source=new DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());db=new JdbcTemplate(source);
        var builder=new LocalContainerEntityManagerFactoryBean();builder.setDataSource(source);
        builder.setJpaVendorAdapter(new HibernateJpaVendorAdapter());builder.setPackagesToScan("com.uten.imp.features.common.taskclaim");
        Properties properties=new Properties();properties.setProperty("hibernate.hbm2ddl.auto","none");builder.setJpaProperties(properties);builder.afterPropertiesSet();
        factory=builder.getObject();em=factory.createEntityManager();
        EntityManager observer=mock(EntityManager.class);
        when(observer.createNativeQuery(anyString())).thenAnswer(call->{lastSql=call.getArgument(0);return em.createNativeQuery(lastSql);});
        // Only query discovery is invoked; no refresh, locking or notification collaborator is mocked out of a write path.
        service=new MaterialAnalysisSupplyWakeupService(observer,null,null,null,null);
        unit=UUID.randomUUID();db.update("INSERT INTO units(id,code,name) VALUES (?,?,'wakeup piece')",unit,"WU-U-"+unit);
        try(var connection=connection()){connection.setAutoCommit(false);actor=ProcurementReceiptFixtureSupport.createActor(connection);connection.commit();}
        maker=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,actor);
    }
    @AfterAll static void stop(){if(em!=null)em.close();if(factory!=null)factory.close();DB.stop();}

    @Test void purchaseAndSubcontractKeepApprovalReverseAndLegacyDimensions() throws Exception {
        for(String type:List.of("PURCHASE","SUBCONTRACT")){
            Scope scope=scope();String method=type.equals("PURCHASE")?"purchaseTargets":"subcontractTargets";
            Receipt resolved=receipt(type,scope.leaf(),scope.goods(),null,1,"RESOLVED",false);
            assertTargets(method,new Object[]{resolved.id(),false},Map.of("sourceDocumentId",resolved.id(),"includeLegacyFallback",false),scope.expected());
            assertTargets(method,new Object[]{resolved.id(),true},Map.of("sourceDocumentId",resolved.id(),"includeLegacyFallback",true),List.of());
            Receipt reversed=receipt(type,scope.leaf(),scope.goods(),null,-1,"REVERSED",false);
            assertTargets(method,new Object[]{reversed.id(),true},Map.of("sourceDocumentId",reversed.id(),"includeLegacyFallback",true),scope.expected());
            assertTargets(method,new Object[]{reversed.id(),false},Map.of("sourceDocumentId",reversed.id(),"includeLegacyFallback",false),List.of());
            Receipt legacy=receipt(type,scope.leaf(),scope.goods(),null,-1,null,false);
            assertTargets(method,new Object[]{legacy.id(),true},Map.of("sourceDocumentId",legacy.id(),"includeLegacyFallback",true),scope.expected());
            // Reversed IQC keeps its colored dimension and excludes the null-color analyses.
            Receipt mismatchedLegacy=receipt(type,scope.leaf(),scope.goods(),scope.blue(),-1,"REVERSED",false);
            assertTargets(method,new Object[]{mismatchedLegacy.id(),true},Map.of("sourceDocumentId",mismatchedLegacy.id(),"includeLegacyFallback",true),List.of(scope.colored()));
            db.update("UPDATE "+type.toLowerCase(Locale.ROOT)+"_receipts SET is_deleted=TRUE WHERE id=?",legacy.id());
            assertTargets(method,new Object[]{legacy.id(),true},Map.of("sourceDocumentId",legacy.id(),"includeLegacyFallback",true),List.of());
        }
    }

    @Test void partialIqcUsesOnlyActuallyStockedSelectedRowsOfTheApprovedReceipt() throws Exception {
        for(String type:List.of("PURCHASE","SUBCONTRACT")){
            Scope scope=scope();Receipt partial=receipt(type,scope.leaf(),scope.goods(),null,1,"PARTIAL",true);
            assertEquals("PARTIAL",db.queryForObject("SELECT status FROM procurement_inspection_items WHERE id=?",String.class,partial.inspection()));
            assertEquals(0,new BigDecimal("4").compareTo(db.queryForObject("SELECT warehouse_stocked_base_qty FROM procurement_inspection_items WHERE id=?",BigDecimal.class,partial.inspection())));
            Map<String,Object> params=Map.of("sourceType",type,"sourceDocumentId",partial.id(),"inspectionItemIds",List.of(partial.inspection()));
            assertTargets("inspectionStockInTargets",new Object[]{type,partial.id(),List.of(partial.inspection())},params,scope.expected());
            assertTargets(type.equals("PURCHASE")?"purchaseTargets":"subcontractTargets",new Object[]{partial.id(),false},
                    Map.of("sourceDocumentId",partial.id(),"includeLegacyFallback",false),List.of());
            Receipt pendingWarehouse=receipt(type,scope.leaf(),scope.goods(),null,1,"PARTIAL",false);
            assertTargets("inspectionStockInTargets",new Object[]{type,pendingWarehouse.id(),List.of(pendingWarehouse.inspection())},
                    Map.of("sourceType",type,"sourceDocumentId",pendingWarehouse.id(),"inspectionItemIds",List.of(pendingWarehouse.inspection())),List.of());
            assertTargets("inspectionStockInTargets",new Object[]{type,partial.id(),List.of(pendingWarehouse.inspection())},
                    Map.of("sourceType",type,"sourceDocumentId",partial.id(),"inspectionItemIds",List.of(pendingWarehouse.inspection())),List.of());
            String wrongType=type.equals("PURCHASE")?"SUBCONTRACT":"PURCHASE";
            assertTargets("inspectionStockInTargets",new Object[]{wrongType,partial.id(),List.of(partial.inspection())},
                    Map.of("sourceType",wrongType,"sourceDocumentId",partial.id(),"inspectionItemIds",List.of(partial.inspection())),List.of());
        }
    }

    @Test void finishedInboundKeepsStatusNullColorSameMainAndReopenedCompletion() throws Exception {
        Scope scope=scope();
        for(int status:List.of(1,-1,0)){
            UUID document=finished(scope.leaf(),scope.goods(),null,status);
            assertTargets("finishedInboundTargets",new Object[]{document,1},Map.of("sourceDocumentId",document,"requiredStatus",1),status==1?scope.expected():List.of());
            assertTargets("finishedInboundTargets",new Object[]{document,-1},Map.of("sourceDocumentId",document,"requiredStatus",-1),status==-1?scope.expected():List.of());
        }
        UUID colored=finished(scope.leaf(),scope.goods(),scope.blue(),1);
        assertTargets("finishedInboundTargets",new Object[]{colored,1},Map.of("sourceDocumentId",colored,"requiredStatus",1),List.of(scope.colored()));
    }

    @Test void unrelatedHistoryIsExcludedBeforeExpensivePredicatesWithRepeatedExplainEvidence() throws Exception {
        Scope scope=scope();Receipt source=receipt("PURCHASE",scope.leaf(),scope.goods(),null,1,"RESOLVED",false);
        Map<String,Object> params=Map.of("sourceDocumentId",source.id(),"includeLegacyFallback",false);
        assertTargets("purchaseTargets",new Object[]{source.id(),false},params,scope.expected());
        String candidate=lastSql,legacy=oldQuery(candidate);
        UUID unrelated=goods();
        new TransactionTemplate(new DataSourceTransactionManager(Objects.requireNonNull(db.getDataSource())))
                .executeWithoutResult(status->{for(int i=0;i<800;i++)analysis(scope.main(),unrelated,null,i%2==0?"ACTIVE":"COMPLETED",true,false,true);});
        for(String table:List.of("production_material_analyses","production_material_analysis_items","production_material_analysis_materials","procurement_inspection_items","purchase_receipts"))db.execute("ANALYZE "+table);
        assertTargets("purchaseTargets",new Object[]{source.id(),false},params,scope.expected());
        // Warm both, alternate order, retain every plan; durations are observations, not a brittle speed assertion.
        explain(legacy,params);explain(candidate,params);
        var oldPlans=new ArrayList<JsonNode>();var newPlans=new ArrayList<JsonNode>();
        for(int i=0;i<5;i++){
            if(i%2==0){oldPlans.add(explain(legacy,params));newPlans.add(explain(candidate,params));}
            else {newPlans.add(explain(candidate,params));oldPlans.add(explain(legacy,params));}
        }
        for(JsonNode plan:newPlans){
            JsonNode dimensions=findPlan(plan.path("Plan"),"Subplan Name","CTE dimensions");
            JsonNode candidates=findPlan(plan.path("Plan"),"Subplan Name","CTE candidates");
            assertNotNull(dimensions);assertEquals(1,dimensions.path("Actual Loops").asInt());
            assertNotNull(candidates);assertTrue(candidates.path("Actual Rows").asInt()<20,"unrelated history never enters warehouse/fulfillment evaluation");
        }
        Path output=Path.of(System.getProperty("uten.wakeup.evidenceDirectory","target/wakeup-query-evidence"));Files.createDirectories(output);
        var mapper=new ObjectMapper();mapper.writerWithDefaultPrettyPrinter().writeValue(output.resolve("old-plans.json").toFile(),oldPlans);
        mapper.writerWithDefaultPrettyPrinter().writeValue(output.resolve("candidate-plans.json").toFile(),newPlans);
        Files.writeString(output.resolve("queries.txt"),"OLD\n"+legacy+"\nCANDIDATE\n"+candidate+"\nPARAMETERS\n"+params);
        String summary="Unrelated analyses added: 800; matching result count: "+scope.expected().size()+"\n"+metrics("old",oldPlans)+metrics("candidate",newPlans);
        Files.writeString(output.resolve("summary.txt"),summary);System.out.println(summary);
    }

    @SuppressWarnings("unchecked")
    private static void assertTargets(String method,Object[] arguments,Map<String,Object> params,List<UUID> expected) throws Exception {
        Class<?>[] types=switch(method){case "inspectionStockInTargets"->new Class[]{String.class,UUID.class,Collection.class};case "finishedInboundTargets"->new Class[]{UUID.class,int.class};default->new Class[]{UUID.class,boolean.class};};
        var selector=MaterialAnalysisSupplyWakeupService.class.getDeclaredMethod(method,types);selector.setAccessible(true);
        var actual=(List<MaterialAnalysisSupplyWakeupService.AnalysisTarget>)selector.invoke(service,arguments);
        String current=lastSql;
        String dimension=dimension(current).replaceAll("\\s+"," ").trim();
        assertEquals(DIMENSION_HASHES.get(method),HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(dimension.getBytes(StandardCharsets.UTF_8))),"source UNION predicates are unchanged");
        var oldRows=(List<Object[]>)bind(em.createNativeQuery(oldQuery(current)),params).getResultList();
        var old=oldRows.stream().map(row->new MaterialAnalysisSupplyWakeupService.AnalysisTarget((UUID)row[0],(UUID)row[1])).toList();
        assertEquals(old,actual,"old/new UUID and maker results, including ordering");
        // PostgreSQL UUID ordering is unsigned lexicographic; Java UUID.compareTo has different signed semantics.
        assertEquals(expected.stream().sorted(Comparator.comparing(UUID::toString)).toList(),actual.stream().map(MaterialAnalysisSupplyWakeupService.AnalysisTarget::analysisId).toList());
    }
    private static String dimension(String sql){return sql.substring(sql.indexOf('(')+1,sql.indexOf("), candidates AS MATERIALIZED ("));}
    private static String oldQuery(String sql){return "WITH dimensions AS ("+dimension(sql)+")\n"+OLD_SELECTOR;}
    private static Query bind(Query query,Map<String,Object> params){params.forEach(query::setParameter);return query;}
    private static JsonNode explain(String sql,Map<String,Object> params) throws Exception {
        String json=bind(em.createNativeQuery("EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,FORMAT JSON) "+sql),params).getSingleResult().toString();
        return new ObjectMapper().readTree(json).get(0);
    }
    private static JsonNode findPlan(JsonNode node,String field,String value){if(value.equals(node.path(field).asText()))return node;for(JsonNode child:node.path("Plans")){JsonNode found=findPlan(child,field,value);if(found!=null)return found;}return null;}
    private static String metrics(String label,List<JsonNode> plans){double[] times=plans.stream().mapToDouble(p->p.path("Execution Time").asDouble()).sorted().toArray();return label+" execution_ms min/median/max="+times[0]+"/"+times[2]+"/"+times[4]+"; shared_hits="+plans.stream().map(p->p.path("Plan").path("Shared Hit Blocks").asInt()).toList()+"\n";}

    private static Scope scope(){
        UUID main=warehouse(null),leaf=warehouse(main),sibling=warehouse(main),other=warehouse(null),goods=goods(),blue=UUID.randomUUID();
        db.update("INSERT INTO colors(id,code,name) VALUES (?,?,'wakeup blue')",blue,"WU-C-"+blue);
        UUID active=analysis(main,goods,null,"ACTIVE",true,false,true);
        db.update("""
                INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,
                    goods_id,color_id,unit_id,depth,path,per_product_qty,required_qty,available_qty,
                    allocated_available_qty,shortage_qty,source_suggestion,active)
                SELECT gen_random_uuid(),analysis_id,analysis_item_id,node_key||'-second-path',goods_id,
                    color_id,unit_id,depth,path||'-second-path',per_product_qty,required_qty,
                    available_qty,allocated_available_qty,shortage_qty,source_suggestion,active
                FROM production_material_analysis_materials WHERE analysis_id=?
                """,active);
        UUID partial=analysis(sibling,goods,null,"PARTIALLY_PLANNED",true,false,true);
        UUID reopened=analysis(main,goods,null,"COMPLETED",true,false,true);
        assertEquals("ACTIVE",db.queryForObject("SELECT fn_material_analysis_fulfillment_status(?)",String.class,reopened));
        UUID complete=analysis(main,goods,null,"COMPLETED",true,false,false);
        assertEquals("COMPLETED",db.queryForObject("SELECT fn_material_analysis_fulfillment_status(?)",String.class,complete));
        analysis(other,goods,null,"ACTIVE",true,false,true);analysis(main,goods,null,"CANCELLED",true,false,true);
        analysis(main,goods,null,"ACTIVE",false,false,true);analysis(main,goods,null,"ACTIVE",true,true,true);
        assertThrows(org.springframework.dao.DataIntegrityViolationException.class,
                ()->analysis(null,goods,null,"ACTIVE",true,false,true),"current schema rejects new warehouse-less analyses");
        UUID colored=analysis(main,goods,blue,"ACTIVE",true,false,true);
        return new Scope(main,leaf,goods,blue,colored,List.of(active,partial,reopened));
    }
    private static UUID analysis(UUID warehouse,UUID goods,UUID color,String status,boolean active,boolean deleted,boolean demand){
        UUID id=UUID.randomUUID(),item=UUID.randomUUID();
        db.update("INSERT INTO production_material_analyses(id,warehouse_id,status,fingerprint,initial_idempotency_key,maker_id,is_deleted,cancelled_by,cancelled_at,cancellation_reason) VALUES (?,?,?,?,?,?,?,?,CASE WHEN ? THEN now() END,?)",id,warehouse,status,"a".repeat(64),"wakeup-"+id,maker,deleted,status.equals("CANCELLED")?actor:null,status.equals("CANCELLED"),status.equals("CANCELLED")?"Query fixture cancellation":null);
        db.update("INSERT INTO production_material_analysis_items(id,analysis_id,source_type,goods_id,color_id,unit_id,source_ref,source_reason,requested_qty,is_deleted) VALUES (?,?,'OTHER',?,?,?,?,'wakeup query fixture',10,?)",item,id,goods,color,unit,"WU-SOURCE-"+item,!demand);
        // Completed without active demand is represented by the existing soft-deleted source item, never fabricated fulfillment.
        db.update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,goods_id,color_id,unit_id,depth,path,per_product_qty,required_qty,available_qty,allocated_available_qty,shortage_qty,source_suggestion,active) VALUES (gen_random_uuid(),?,?,?,?,?,?,1,?,1,10,0,0,10,'BUY',?)",id,item,"node-"+item,goods,color,unit,"node-"+item,active);
        return id;
    }
    private static Receipt receipt(String type,UUID warehouse,UUID goods,UUID color,int status,String quality,boolean stocked) throws Exception {
        String prefix=type.toLowerCase(Locale.ROOT),bill=(type.equals("PURCHASE")?"CJ":"EJ")+"20260908"+NUMBERS.incrementAndGet();
        UUID id=UUID.randomUUID(),item=UUID.randomUUID(),inspection=quality==null?null:UUID.randomUUID();
        try(var c=connection()){
            c.setAutoCommit(false);
            execute(c,"INSERT INTO "+prefix+"_receipts(id,bill_no,bill_date,warehouse_id,status,exchange_rate,total_original,total_local) VALUES (?,?,DATE '2026-09-08',?,?,1,0,0)",id,bill,warehouse,status);
            execute(c,"INSERT INTO "+prefix+"_receipt_items(id,bill_no,bill_date,receipt_id,line_no,goods_id,color_id,unit_id,unit_rate,qty,price,amount_original,amount_local,replacement_intent,goods_snapshot_source) VALUES (?,?,DATE '2026-09-08',?,1,?,?,?,1,10,0,0,0,'NORMAL','MASTER_AT_SAVE')",item,bill,id,goods,color,unit);
            if(status==1)ProcurementReceiptFixtureSupport.appendStandardReceipt(c,type,id,actor);
            if(quality!=null){
                execute(c,"INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,receipt_item_id,warehouse_id,goods_id,color_id,unit_id,unit_rate,received_base_qty,received_amount_local,status) VALUES (?,?,?,?,?,?,?,?,1,10,0,?)",inspection,type,id,item,warehouse,goods,color,unit,quality.equals("REVERSED")?"REVERSED":"PENDING");
                if(quality.equals("RESOLVED"))ProcurementReceiptFixtureSupport.recordZeroPriceQualityDecision(c,inspection,"FAIL",BigDecimal.TEN,actor);
                if(quality.equals("PARTIAL"))ProcurementReceiptFixtureSupport.recordZeroPriceQualityDecision(c,inspection,"PASS",new BigDecimal("4"),actor);
            }
            c.commit();
        }
        if(stocked)try(var c=connection()){ProcurementReceiptFixtureSupport.stockZeroPricePasses(c,List.of(inspection));}
        return new Receipt(id,inspection);
    }
    private static UUID finished(UUID warehouse,UUID goods,UUID color,int status){UUID id=UUID.randomUUID();String bill="CR20260908"+NUMBERS.incrementAndGet();db.update("INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,warehouse_id,status) VALUES (?,'FINISHED_IN',?,DATE '2026-09-08',?,?)",id,bill,warehouse,status);db.update("INSERT INTO stock_document_items(id,doc_id,bill_type,bill_no,bill_date,line_no,goods_id,color_id,unit_id,unit_rate,qty,base_qty,goods_snapshot_source) VALUES (gen_random_uuid(),?,'FINISHED_IN',?,DATE '2026-09-08',1,?,?,?,1,10,10,'MASTER_AT_SAVE')",id,bill,goods,color,unit);return id;}
    private static UUID goods(){UUID id=UUID.randomUUID();db.update("INSERT INTO goods(id,code,name,unit_id,code_sequence) VALUES (?,?,'wakeup goods',?,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))",id,"WU-G-"+id,unit);return id;}
    private static UUID warehouse(UUID parent){UUID id=UUID.randomUUID();db.update("INSERT INTO warehouses(id,code,name,parent_id) VALUES (?,?,'wakeup warehouse',?)",id,"WU-W-"+id,parent);return id;}
    private static Connection connection() throws Exception{return DriverManager.getConnection(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());}
    private static void execute(Connection connection,String sql,Object...params) throws Exception{try(var query=connection.prepareStatement(sql)){for(int i=0;i<params.length;i++)query.setObject(i+1,params[i]);query.execute();}}
    private record Receipt(UUID id,UUID inspection){}
    private record Scope(UUID main,UUID leaf,UUID goods,UUID blue,UUID colored,List<UUID> expected){}
}
