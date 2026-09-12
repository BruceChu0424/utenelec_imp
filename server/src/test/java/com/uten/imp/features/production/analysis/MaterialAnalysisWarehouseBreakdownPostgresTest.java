package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.sql.Connection;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.postgresql.PGStatement;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterUtils;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** The actual V554 source-progress view and V489 warehouse function run on
 * synthetic input facts. Stock/entitlement summaries are fixed facts here;
 * their physical ledger correctness retains its separate end-to-end tests. */
@Testcontainers(disabledWithoutDocker = true)
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class MaterialAnalysisWarehouseBreakdownPostgresTest {
    @Container static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID ANALYSIS=id("analysis"),OTHER_ANALYSIS=id("other-analysis");
    private static final UUID G=id("goods"),G2=id("goods-2"),G3=id("excluded-goods"),BLUE=id("blue");
    private static final UUID UNIT=id("unit"),OTHER_UNIT=id("other-unit");
    private static final UUID MAIN=id("main"),LEAF=id("leaf"),SIBLING=id("sibling"),BAD=id("bad"),OTHER=id("other");
    private static DriverManagerDataSource source;
    private static JdbcTemplate jdbc;
    private static String original;
    private static final ObjectMapper JSON=new ObjectMapper();
    private static final List<Map<String,Object>> evidence=new ArrayList<>();
    private static final List<String> TABLES=List.of("warehouses","goods","production_material_analysis_materials",
            "stock_facts","stock_reservations","preplan_stock_entitlement_events","entitlement_facts",
            "preplan_supply_actions","preplan_supply_action_allocations","purchase_requests","purchase_request_items",
            "purchase_orders","purchase_order_items","purchase_receipts","purchase_receipt_items",
            "procurement_inspection_items","procurement_iqc_rejection_cases","purchase_order_item_sources");

    @BeforeAll static void database() throws Exception {
        source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());jdbc=new JdbcTemplate(source);
        jdbc.execute("CREATE TABLE warehouses(id uuid PRIMARY KEY,parent_id uuid,code text,name text,is_deleted boolean,is_accountable boolean,is_defective boolean)");
        jdbc.execute("CREATE TABLE goods(id uuid PRIMARY KEY,min_qty numeric)");
        jdbc.execute("CREATE TABLE production_material_analysis_materials(id uuid PRIMARY KEY,analysis_id uuid,goods_id uuid,color_id uuid,unit_id uuid,active boolean)");
        jdbc.execute("CREATE INDEX ON production_material_analysis_materials(analysis_id,goods_id)");
        jdbc.execute("CREATE TABLE stock_facts(warehouse_id uuid,goods_id uuid,color_id uuid,on_hand_qty numeric,reserved_qty numeric,available_qty numeric)");
        jdbc.execute("CREATE VIEW v_stock_available AS SELECT * FROM stock_facts");
        jdbc.execute("CREATE TABLE stock_reservations(id uuid PRIMARY KEY,warehouse_id uuid,goods_id uuid,color_id uuid,is_deleted boolean,status integer,owner_type text,owner_id uuid,qty numeric,consumed_qty numeric,released_qty numeric)");
        jdbc.execute("CREATE INDEX ON stock_reservations(warehouse_id,goods_id,color_id)");
        jdbc.execute("CREATE TABLE preplan_stock_entitlement_events(stock_reservation_id uuid)");
        jdbc.execute("CREATE TABLE entitlement_facts(stock_reservation_id uuid,beneficiary_analysis_id uuid,beneficiary_analysis_material_id uuid,effective_qty numeric)");
        jdbc.execute("CREATE VIEW v_preplan_stock_entitlement_beneficiary_balance AS SELECT * FROM entitlement_facts");
        jdbc.execute("CREATE TABLE preplan_supply_actions(id uuid PRIMARY KEY,route text,status text,warehouse_id uuid,goods_id uuid,color_id uuid,requested_qty numeric,safety_replenishment_qty numeric,safety_external_item_id uuid,external_document_id uuid)");
        jdbc.execute("CREATE INDEX ON preplan_supply_actions(warehouse_id,goods_id,color_id)");
        jdbc.execute("CREATE TABLE preplan_supply_action_allocations(action_id uuid,external_item_id uuid)");
        jdbc.execute("CREATE INDEX ON preplan_supply_action_allocations(action_id)");
        jdbc.execute("CREATE TABLE purchase_requests(id uuid PRIMARY KEY,is_deleted boolean,status integer,is_stopped boolean)");
        jdbc.execute("CREATE TABLE purchase_request_items(id uuid PRIMARY KEY,request_id uuid,qty numeric,ordered_qty numeric,unit_rate numeric,is_deleted boolean)");
        jdbc.execute("CREATE TABLE purchase_orders(id uuid PRIMARY KEY,status integer,is_deleted boolean)");
        jdbc.execute("CREATE TABLE purchase_order_items(id uuid PRIMARY KEY,order_id uuid,qty numeric,received_qty numeric,returned_qty numeric,unit_rate numeric,is_deleted boolean)");
        jdbc.execute("CREATE TABLE purchase_receipts(id uuid PRIMARY KEY,status integer,is_deleted boolean)");
        jdbc.execute("CREATE TABLE purchase_receipt_items(id uuid PRIMARY KEY,order_item_id uuid,receipt_id uuid,qty numeric,unit_rate numeric,is_deleted boolean)");
        jdbc.execute("CREATE TABLE procurement_inspection_items(id uuid PRIMARY KEY,receipt_item_id uuid,receipt_type text,status text,warehouse_stocked_base_qty numeric,failed_base_qty numeric,received_base_qty numeric)");
        jdbc.execute("CREATE TABLE procurement_iqc_rejection_cases(order_item_id uuid,receipt_type text,failed_base_qty numeric,is_deleted boolean,return_recorded_at timestamptz,status text)");
        jdbc.execute("CREATE TABLE purchase_order_item_sources(id uuid PRIMARY KEY,order_item_id uuid,request_item_id uuid,alloc_qty numeric,line_no integer)");
        jdbc.execute("CREATE INDEX ON purchase_order_item_sources(request_item_id)");
        String migration=Files.readString(Path.of("src/main/resources/db/migration/V554__procurement_source_remaining_supply.sql"));
        jdbc.execute(function(migration,"fn_procurement_bounded_interval_qty"));
        jdbc.execute(migration.substring(migration.indexOf("CREATE OR REPLACE VIEW v_preplan_buy_action_slice_progress")));
        jdbc.execute(function(Files.readString(Path.of("src/main/resources/db/migration/V489__same_main_warehouse_material_fulfillment.sql")),"fn_warehouse_main_id"));
        original=Files.readString(Path.of("src/test/resources/fixtures/material-analysis/warehouse-breakdown-v557-before.sql"));
    }

    @BeforeEach void facts() {
        jdbc.execute("TRUNCATE "+String.join(",",TABLES));
        warehouse(MAIN,null,"A",false,true,false);warehouse(LEAF,MAIN,"A1",false,true,false);
        warehouse(SIBLING,MAIN,"A2",false,true,false);warehouse(BAD,MAIN,"A3",false,true,true);
        warehouse(OTHER,null,"B",false,true,false);
        warehouse(id("deleted"),LEAF,"Z",true,true,false);warehouse(id("non-accountable"),null,"N",false,false,false);
        jdbc.update("INSERT INTO goods VALUES (?,5),(?,NULL),(?,-2)",G,G2,G3);
        material("g-null",ANALYSIS,G,null,UNIT,true);material("g-second-unit",ANALYSIS,G,null,OTHER_UNIT,true);
        material("g-blue",ANALYSIS,G,BLUE,UNIT,true);material("g2",ANALYSIS,G2,null,UNIT,true);
        material("inactive",ANALYSIS,G3,null,UNIT,false);material("foreign",OTHER_ANALYSIS,G3,null,UNIT,true);
        jdbc.update("INSERT INTO stock_facts VALUES (?,?,NULL,50,32,18),(?,?,?,2,5,-3),(?,?,NULL,3,0,3)",LEAF,G,LEAF,G,BLUE,BAD,G);
        reservation("legacy",ANALYSIS,"10","2","1");reservation("other",OTHER_ANALYSIS,"5","0","0");
        reservation("tracked",OTHER_ANALYSIS,"20","0","0");
        jdbc.update("INSERT INTO preplan_stock_entitlement_events VALUES (?),(?)",id("tracked"),id("tracked"));
        jdbc.update("INSERT INTO entitlement_facts VALUES (?,?,?,3.5),(?,?,?,50),(?,?,?,8)",
                id("tracked"),ANALYSIS,id("g-null"),id("tracked"),ANALYSIS,id("inactive"),id("tracked"),OTHER_ANALYSIS,id("foreign"));
        Action ordered=action("ordered-safety",G,null,LEAF,"10","10",true,false,false,"CREATED");
        UUID order=orderedReceipt("small-order","6","4","2","1","1");
        orderSource(order,ordered.item(),"6",1);
        action("legacy-zero-declared",G,null,LEAF,"0","5",true,false,false,"CREATED");
        action("blue-safety",G,BLUE,LEAF,"2","2",true,false,false,"CREATED");
        action("other-warehouse",G,null,OTHER,"4","4",true,false,false,"CREATED");
        action("stopped",G,null,LEAF,"99","99",true,true,false,"CREATED");
        action("deleted-request",G,null,LEAF,"99","99",true,false,true,"CREATED");
        action("cancelled",G,null,LEAF,"99","99",true,false,false,"CANCELLED");
        action("outside-dimensions",G3,null,LEAF,"99","99",true,false,false,"CREATED");
        action("outside-warehouses",G,null,id("deleted"),"99","99",true,false,false,"CREATED");
        action("pure-demand",G,null,LEAF,"0","100",false,false,false,"CREATED");
    }

    @Test void candidateRetainsEveryQuantityWarehouseFlagNullAndUnitIdentity() throws Exception {
        var before=rows(original);var after=rows(MaterialAnalysisWarehouseBreakdownReader.SQL);
        assertEquals(before,after);assertEquals(20,after.size());
        assertEquals(bd("13"),row(after,G,null,UNIT,LEAF).get(11),"Recorded returned failure reopens safety supply; zero declared legacy safety is not discarded");
        assertEquals(bd("13"),row(after,G,null,OTHER_UNIT,LEAF).get(11),"Two display units must not double the shared safety dimension");
        assertEquals(bd("10.5"),row(after,G,null,UNIT,LEAF).get(9));
        assertEquals(bd("2"),row(after,G,BLUE,UNIT,LEAF).get(11));
        assertEquals(BigDecimal.ZERO,row(after,G,BLUE,UNIT,LEAF).get(8));
        assertEquals(bd("4"),row(after,G,null,UNIT,OTHER).get(11));
        assertEquals(Boolean.FALSE,row(after,G,null,UNIT,MAIN).get(12));
        assertEquals(Boolean.FALSE,row(after,G,null,UNIT,BAD).get(12));
        assertEquals(Boolean.TRUE,row(after,G,null,UNIT,LEAF).get(12));
        assertEquals(MAIN,row(after,G,null,UNIT,LEAF).get(13));
        assertEquals(OTHER,row(after,G,null,UNIT,OTHER).get(13));
        assertEquals(BigDecimal.ZERO,row(after,G2,null,UNIT,LEAF).get(10));
        assertEquals(before,rows(captureCurrentService()),"The query actually called by the service must retain this contract");
    }

    @Test void mergedSafetySourcesKeepTheirOriginalFifoReturnIntervals() throws Exception {
        Action a=action("merged-a",G2,null,LEAF,"20","20",true,false,false,"CREATED");
        Action b=action("merged-b",G2,null,LEAF,"30","30",true,false,false,"CREATED");
        UUID order=orderedReceipt("merged-order","50","50","12","38","38");
        orderSource(order,a.item(),"20",1);orderSource(order,b.item(),"30",2);
        assertEquals(0,new BigDecimal("8").compareTo(jdbc.queryForObject("SELECT safety_future_qty FROM v_preplan_buy_action_slice_progress WHERE action_id=?",BigDecimal.class,a.id())));
        assertEquals(0,new BigDecimal("30").compareTo(jdbc.queryForObject("SELECT safety_future_qty FROM v_preplan_buy_action_slice_progress WHERE action_id=?",BigDecimal.class,b.id())));
        var expected=rows(original);var actual=rows(MaterialAnalysisWarehouseBreakdownReader.SQL);
        assertEquals(expected,actual);assertEquals(bd("38"),row(actual,G2,null,UNIT,LEAF).get(11));
    }

    @ParameterizedTest @ValueSource(strings={"force_custom_plan","force_generic_plan","auto"})
    void manyDemandActionsDoNotRepeatTheWholeSafetyProgressViewPerDimension(String mode) throws Exception {
        jdbc.execute("INSERT INTO goods SELECT md5('perf-g-'||i)::uuid,0 FROM generate_series(0,79)g(i)");
        jdbc.update("INSERT INTO production_material_analysis_materials SELECT md5('perf-m-'||i)::uuid,?,md5('perf-g-'||((i-1)%80))::uuid,NULL,?,TRUE FROM generate_series(1,8000)g(i)",ANALYSIS,UNIT);
        jdbc.execute("INSERT INTO purchase_requests SELECT md5('perf-a-'||i)::uuid,FALSE,0,FALSE FROM generate_series(1,1000)g(i)");
        jdbc.execute("INSERT INTO purchase_request_items SELECT id,id,1,0,1,FALSE FROM purchase_requests WHERE id NOT IN (SELECT request_id FROM purchase_request_items)");
        jdbc.update("""
                INSERT INTO preplan_supply_actions
                SELECT md5('perf-a-'||i)::uuid,'BUY','CREATED',?,
                       CASE WHEN i<=500 THEN md5('perf-g-'||(i%80))::uuid ELSE CAST(? AS uuid) END,
                       NULL,1,0,NULL,md5('perf-a-'||i)::uuid FROM generate_series(1,1000)g(i)
                """,LEAF,G3);
        jdbc.execute("INSERT INTO preplan_supply_action_allocations SELECT id,id FROM preplan_supply_actions WHERE id=external_document_id");
        for(String table:TABLES)jdbc.execute("ANALYZE "+table);
        try(Connection connection=source.getConnection()) {
            connection.setAutoCommit(false);connection.setReadOnly(true);
            try(var settings=connection.createStatement()) {
                settings.execute("SET LOCAL jit=off");settings.execute("SET LOCAL statement_timeout='30s'");
                settings.execute("SET LOCAL plan_cache_mode="+mode);
            }
            var expected=rows(connection,original);var actual=rows(connection,MaterialAnalysisWarehouseBreakdownReader.SQL);
            assertEquals(expected,actual);assertEquals(420,actual.size());
            JsonNode oldPlan=plan(connection,original),newPlan=plan(connection,MaterialAnalysisWarehouseBreakdownReader.SQL);
            double oldReads=actionReads(oldPlan),newReads=actionReads(newPlan);
            evidence.add(Map.of("planMode",mode,"rows",actual.size(),"originalActionRowsVisited",oldReads,
                    "candidateActionRowsVisited",newReads,"original",oldPlan,"candidate",newPlan));
            Path output=Path.of(System.getProperty("uten.build.directory","target"),"warehouse-breakdown-query-evidence.json");
            Files.createDirectories(output.getParent());JSON.writerWithDefaultPrettyPrinter().writeValue(output.toFile(),evidence);
            assertTrue(newReads<oldReads,"Safety progress must be aggregated once, not rescanned for every dimension/warehouse: "+oldReads+" -> "+newReads);
            connection.rollback();
        }
    }

    private static String captureCurrentService() {
        EntityManager em=mock(EntityManager.class);Query query=mock(Query.class);AtomicReference<String> captured=new AtomicReference<>();
        when(em.createNativeQuery(anyString())).thenAnswer(call->{assertNull(captured.get());captured.set(call.getArgument(0));return query;});
        when(query.setParameter(anyString(),any())).thenReturn(query);when(query.getResultList()).thenReturn(new ArrayList<>());
        var materials=new ArrayList<MaterialAnalysisService.MaterialRow>();
        for(UUID goods:jdbc.queryForList("SELECT DISTINCT goods_id FROM production_material_analysis_materials WHERE analysis_id=? AND active",UUID.class,ANALYSIS)) {
            var material=mock(MaterialAnalysisService.MaterialRow.class);when(material.goodsId()).thenReturn(goods);
            when(material.dimension()).thenReturn(new MaterialAnalysisService.MaterialDimension(goods,null,UNIT));materials.add(material);
        }
        MaterialAnalysisService service=mock(MaterialAnalysisService.class,CALLS_REAL_METHODS);ReflectionTestUtils.setField(service,"em",em);
        ReflectionTestUtils.invokeMethod(service,"warehouseBreakdown",ANALYSIS,materials,new MaterialAnalysisService.SharedFutureIndex(Map.of()),Map.of());
        assertNotNull(captured.get());return captured.get();
    }

    private static Map<String,List<Object>> rows(String sql) throws Exception {
        try(Connection connection=source.getConnection()) {try(var settings=connection.createStatement()){settings.execute("SET jit=off");}return rows(connection,sql);}
    }
    private static Map<String,List<Object>> rows(Connection connection,String sql) throws Exception {
        var parsed=NamedParameterUtils.parseSqlStatement(sql);var values=parameters();
        try(var statement=connection.prepareStatement(NamedParameterUtils.substituteNamedParameters(parsed,values))) {
            statement.unwrap(PGStatement.class).setPrepareThreshold(1);
            Object[] bindings=NamedParameterUtils.buildValueArray(parsed,values,null);
            for(int index=0;index<bindings.length;index++)statement.setObject(index+1,bindings[index]);
            Map<String,List<Object>> result=new TreeMap<>();
            try(var rows=statement.executeQuery()) {while(rows.next()) {
                List<Object> row=new ArrayList<>();for(int column=1;column<=14;column++){Object value=rows.getObject(column);row.add(value instanceof BigDecimal number?number.stripTrailingZeros():value);}
                assertNull(result.put(key((UUID)row.get(0),(UUID)row.get(1),(UUID)row.get(2),(UUID)row.get(3)),row),"Duplicate material/warehouse dimension");
            }}return result;
        }
    }
    private static JsonNode plan(Connection connection,String sql) throws Exception {
        var parsed=NamedParameterUtils.parseSqlStatement(sql);var values=parameters();
        try(var statement=connection.prepareStatement("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) "+NamedParameterUtils.substituteNamedParameters(parsed,values))) {
            statement.unwrap(PGStatement.class).setPrepareThreshold(1);
            Object[] bindings=NamedParameterUtils.buildValueArray(parsed,values,null);for(int index=0;index<bindings.length;index++)statement.setObject(index+1,bindings[index]);
            try(var result=statement.executeQuery()){assertTrue(result.next());return JSON.readTree(result.getString(1)).get(0);}
        }
    }
    private static MapSqlParameterSource parameters() {
        List<String> goods=jdbc.queryForList("SELECT DISTINCT goods_id::text FROM production_material_analysis_materials WHERE analysis_id=? AND active ORDER BY goods_id::text",String.class,ANALYSIS);
        return new MapSqlParameterSource(Map.of("analysisId",ANALYSIS,"goodsIds",String.join(",",goods)));
    }
    private static double actionReads(JsonNode node) {
        double sum=0;if(node.isObject()) {
            if("preplan_supply_actions".equals(node.path("Relation Name").asText()))sum=(node.path("Actual Rows").asDouble()+node.path("Rows Removed by Filter").asDouble())*node.path("Actual Loops").asDouble(1);
            var fields=node.elements();while(fields.hasNext())sum+=actionReads(fields.next());
        } else if(node.isArray())for(JsonNode child:node)sum+=actionReads(child);return sum;
    }
    private static List<Object> row(Map<String,List<Object>> rows,UUID goods,UUID color,UUID unit,UUID warehouse){return rows.get(key(goods,color,unit,warehouse));}
    private static String key(UUID goods,UUID color,UUID unit,UUID warehouse){return goods+"|"+color+"|"+unit+"|"+warehouse;}
    private static void warehouse(UUID id,UUID parent,String code,boolean deleted,boolean accountable,boolean defective){jdbc.update("INSERT INTO warehouses VALUES (?,?,?,?,?,?,?)",id,parent,code,code,deleted,accountable,defective);}
    private static void material(String id,UUID analysis,UUID goods,UUID color,UUID unit,boolean active){jdbc.update("INSERT INTO production_material_analysis_materials VALUES (?,?,?,?,?,?)",id(id),analysis,goods,color,unit,active);}
    private static void reservation(String seed,UUID owner,String quantity,String consumed,String released){jdbc.update("INSERT INTO stock_reservations VALUES (?,?,?,NULL,FALSE,0,'PREPLAN_ANALYSIS',?,?,?,?)",id(seed),LEAF,G,owner,new BigDecimal(quantity),new BigDecimal(consumed),new BigDecimal(released));}
    private record Action(UUID id,UUID item) {}
    private static Action action(String seed,UUID goods,UUID color,UUID warehouse,String safety,String quantity,boolean safetySlice,boolean stopped,boolean deleted,String status) {
        UUID action=id(seed+"-action"),request=id(seed+"-request"),item=id(seed+"-item");
        jdbc.update("INSERT INTO purchase_requests VALUES (?,?,0,?)",request,deleted,stopped);
        jdbc.update("INSERT INTO purchase_request_items VALUES (?,?,?,0,1,FALSE)",item,request,new BigDecimal(quantity));
        jdbc.update("INSERT INTO preplan_supply_actions VALUES (?,'BUY',?,?,?,?,?,?,?,?)",action,status,warehouse,goods,color,
                safetySlice?BigDecimal.ZERO:new BigDecimal(quantity),new BigDecimal(safety),safetySlice?item:null,request);
        if(!safetySlice)jdbc.update("INSERT INTO preplan_supply_action_allocations VALUES (?,?)",action,item);return new Action(action,item);
    }
    private static UUID orderedReceipt(String seed,String quantity,String received,String qualified,String failed,String returnedFailure) {
        UUID order=id(seed+"-order"),item=id(seed+"-order-item"),receipt=id(seed+"-receipt"),receiptItem=id(seed+"-receipt-item");
        jdbc.update("INSERT INTO purchase_orders VALUES (?,1,FALSE)",order);
        jdbc.update("INSERT INTO purchase_order_items VALUES (?,?,?,?,0,1,FALSE)",item,order,new BigDecimal(quantity),new BigDecimal(received));
        jdbc.update("INSERT INTO purchase_receipts VALUES (?,1,FALSE)",receipt);
        jdbc.update("INSERT INTO purchase_receipt_items VALUES (?,?,?,?,1,FALSE)",receiptItem,item,receipt,new BigDecimal(received));
        String status=new BigDecimal(qualified).add(new BigDecimal(failed)).compareTo(new BigDecimal(received))==0?"RESOLVED":"PARTIAL";
        jdbc.update("INSERT INTO procurement_inspection_items VALUES (?,?,'PURCHASE',?,?,?,?)",id(seed+"-inspection"),receiptItem,status,new BigDecimal(qualified),new BigDecimal(failed),new BigDecimal(received));
        jdbc.update("INSERT INTO procurement_iqc_rejection_cases VALUES (?,'PURCHASE',?,FALSE,now(),'RETURN_RECORDED')",item,new BigDecimal(returnedFailure));return item;
    }
    private static void orderSource(UUID orderItem,UUID requestItem,String quantity,int line){jdbc.update("INSERT INTO purchase_order_item_sources VALUES (?,?,?,?,?)",id(orderItem+"|"+requestItem),orderItem,requestItem,new BigDecimal(quantity),line);jdbc.update("UPDATE purchase_request_items SET ordered_qty=? WHERE id=?",new BigDecimal(quantity),requestItem);}
    private static String function(String sql,String name){int start=sql.indexOf("CREATE OR REPLACE FUNCTION "+name+"(");assertTrue(start>=0);int end=sql.indexOf("$$;",start);assertTrue(end>start);return sql.substring(start,end+3);}
    private static BigDecimal bd(String value){return new BigDecimal(value).stripTrailingZeros();}
    private static UUID id(String seed){try{var bytes=ByteBuffer.wrap(MessageDigest.getInstance("MD5").digest(seed.getBytes(StandardCharsets.UTF_8)));return new UUID(bytes.getLong(),bytes.getLong());}catch(Exception failure){throw new IllegalStateException(failure);}}
}
