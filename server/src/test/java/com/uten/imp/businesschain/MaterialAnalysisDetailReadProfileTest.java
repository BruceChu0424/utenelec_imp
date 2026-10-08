package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import javax.sql.DataSource;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;

import static org.junit.jupiter.api.Assertions.*;

/** Read-only plans and complete response parity on the real three-product ordering lifecycle. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@Import(ProductionJdbcMeasurement.Configuration.class)
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class MaterialAnalysisDetailReadProfileTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired DataSource dataSource;
    @Autowired ObjectMapper json;
    private AggregateMaterialOrderEndToEndTest h;
    @BeforeEach void before(){h=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(h);h.before();}
    @AfterEach void after(){ProductionJdbcMeasurement.end();h.after();}

    @Test void orderedThreeProductDetailHasStableCompleteFactsAndInspectableReadPlans() throws Exception {
        var scenario=h.createThreeProductScreenshotCase("100");var c=scenario.data();
        h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.material(),"MAKE","400",true),h.input(c,scenario.bag(),"BUY","400",true))));
        List<GroupInput> later=scenario.laterRoutes().entrySet().stream().map(entry->h.input(c,entry.getKey(),entry.getValue(),
                entry.getKey().equals(scenario.tape())?"0.15":"300",false)).toList();
        for(GroupInput group:later)h.writer.submit(c.analysis(),h.command(c,List.of(group)));
        AnalysisView stable=h.analyses.detail(c.analysis());
        JsonNode expected=json.valueToTree(stable);
        var measurements=new ArrayList<Map<String,Object>>();
        ProductionJdbcMeasurement.Sample last=null;
        for(int sample=0;sample<5;sample++) {
            for(boolean legacy:sample%2==0?List.of(true,false):List.of(false,true)) {
            var sql=ProductionJdbcMeasurement.begin();long started=System.nanoTime();AnalysisView current;
            try{current=readDetail(c.analysis(),legacy);}finally{ProductionJdbcMeasurement.end();}
            double millis=(System.nanoTime()-started)/1_000_000d;
            assertEquals(expected,json.valueToTree(current),"Every quantity, source UUID, authority flag and downstream identity must be unchanged");
            measurements.add(Map.of("sample",sample,"variant",legacy?"legacy":"candidate","elapsedMillis",millis,"materialRows",current.flatMaterials().size(),"sql",sql.result()));
            if(!legacy)last=sql;
            }
        }
        var output=Path.of(System.getProperty("uten.build.directory","target"),"material-detail-profile.json");Files.createDirectories(output.getParent());
        var result=new LinkedHashMap<String,Object>();result.put("measurements",measurements);result.put("completeSnapshotParity",true);
        result.put("statementOrigins",last.statementOrigins);result.put("plans",explain(last));
        json.writerWithDefaultPrettyPrinter().writeValue(output.toFile(),result);
        var transaction=new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class));
        transaction.executeWithoutResult(status->{
            var appended=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.material(),"MAKE","1",true))));
            assertEquals(1,h.db.queryForObject("SELECT count(*) FROM preplan_aggregate_batch_events event JOIN preplan_aggregate_batches batch ON batch.id=event.batch_id WHERE batch.analysis_id=? AND event.event_type='APPEND' AND event.transaction_id=txid_current()",Integer.class,c.analysis()));
            AnalysisView current=readDetail(c.analysis(),false),legacy=readDetail(c.analysis(),true);
            assertEquals(json.valueToTree(legacy),json.valueToTree(current),"Current-transaction MAKE append remains governed by the real growability function");
            assertTrue(current.flatMaterials().stream().filter(row->row.goodsId().equals(c.material()))
                    .flatMap(row->row.downstreamReferences().stream()).anyMatch(ref->ref.growableLineQty()!=null));
            assertFalse(appended.batches().isEmpty());status.setRollbackOnly();
        });
    }

    private AnalysisView readDetail(UUID analysis,boolean legacy) {
        if(!legacy)return h.analyses.detail(analysis);
        Object service=org.springframework.test.util.AopTestUtils.getUltimateTargetObject(h.analyses);
        var original=(jakarta.persistence.EntityManager)org.springframework.test.util.ReflectionTestUtils.getField(service,"em");
        var oracle=(jakarta.persistence.EntityManager)java.lang.reflect.Proxy.newProxyInstance(
                jakarta.persistence.EntityManager.class.getClassLoader(),new Class<?>[]{jakarta.persistence.EntityManager.class},(proxy,method,args)->{
                    Object[] actual=args;
                    if(method.getName().equals("createNativeQuery")&&args!=null&&args.length>0&&args[0] instanceof String sql){
                        actual=args.clone();actual[0]=legacySql(sql);
                    }
                    try{return method.invoke(original,actual);}catch(java.lang.reflect.InvocationTargetException failure){throw failure.getCause();}
                });
        org.springframework.test.util.ReflectionTestUtils.setField(service,"em",oracle);
        try{return h.analyses.detail(analysis);}finally{org.springframework.test.util.ReflectionTestUtils.setField(service,"em",original);}
    }

    /** Frozen correctness-commit reads remain independent oracles; no production fallback is added. */
    private static String legacySql(String sql){
        if(sql.contains("source_budgets AS MATERIALIZED")&&sql.contains("preceding_capacity"))return com.uten.imp.features.production.analysis.AggregateAliasCoverageSqlOracle.SQL;
        if(sql.contains("WITH sources AS MATERIALIZED")&&sql.contains("SELECT material.id,source.kind"))
            return sql.replace("WITH sources AS MATERIALIZED","WITH sources AS");
        if(sql.contains("WITH current_appends AS MATERIALIZED")&&sql.contains("growable_order_qty")){
            String old="WITH "+sql.substring(sql.indexOf("selected_actions AS MATERIALIZED"));
            int start=old.indexOf("CASE WHEN action.route='MAKE'");int function=old.indexOf("fn_preplan_supply_action_growable(action.id)",start);
            return old.substring(0,start)+"CASE WHEN "+old.substring(function);
        }
        return sql;
    }

    private List<Map<String,Object>> explain(ProductionJdbcMeasurement.Sample sample) throws Exception {
        var result=new ArrayList<Map<String,Object>>();
        try(var connection=dataSource.getConnection()) {
            connection.setReadOnly(true);connection.setAutoCommit(false);
            try {
                for(var query:sample.explainCandidates.values()) {
                    try(var statement=connection.prepareStatement("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) "+query.sql())) {
                        query.bind(statement);
                        try(var rows=statement.executeQuery()) {
                            assertTrue(rows.next());
                            result.add(Map.of("fingerprint",query.fingerprint(),"plan",safePlan(json.readTree(rows.getString(1)))));
                        }
                    }
                }
            } finally {connection.rollback();}
        }
        return result;
    }

    private static Object safePlan(JsonNode node) {
        if(node.isArray()){List<Object> result=new ArrayList<>();node.forEach(value->result.add(safePlan(value)));return result;}
        if(!node.isObject())return node.isNumber()?node.numberValue():node.isBoolean()?node.booleanValue():node.asText();
        var result=new LinkedHashMap<String,Object>();
        var keys=Set.of("Plan","Plans","Node Type","Relation Name","Index Name","Actual Rows","Actual Loops","Actual Startup Time","Actual Total Time",
                "Rows Removed by Filter","Rows Removed by Index Recheck","Plan Rows","Planning Time","Execution Time","Total Cost","Startup Cost",
                "Shared Hit Blocks","Shared Read Blocks","Temp Read Blocks","Temp Written Blocks","JIT","Functions","Options","Timing",
                "Generation","Inlining","Optimization","Emission","Total","Expressions","Deforming");
        node.properties().forEach(entry->{if(keys.contains(entry.getKey()))result.put(entry.getKey(),safePlan(entry.getValue()));});
        return result;
    }
}
