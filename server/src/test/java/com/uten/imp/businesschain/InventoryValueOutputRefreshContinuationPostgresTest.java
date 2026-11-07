package com.uten.imp.businesschain;

import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.features.stock.valuation.InventoryValueWorkService;
import com.uten.imp.application.port.InventoryProductionCostPort;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.Savepoint;
import java.util.*;

import static org.junit.jupiter.api.Assertions.*;

/** Genuine pre-fix confirmation, forward migration and worker continuation.
 * Corruption probes use nonempty catalog copies, never disable a live guard. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","spring.flyway.target=1065",
        "spring.jpa.mapping-resources="+HistoricalOrmMappings.BEFORE_V1097,
        HistoricalInventoryPlanningSql.BEFORE_V1097_PROPERTY,
        "uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.read-summary.compaction-enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only"})
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
class InventoryValueOutputRefreshContinuationPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("uten_imp").withUsername("fixture_admin").withPassword("uten")
            .withCommand("postgres","-c","max_connections=400");
    private static Path attachments;
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) throws Exception {
        PG.start();attachments=Files.createTempDirectory("uten-value-continuation-");
        FixtureDatabaseProperties.bindSameRole(registry,PG::getJdbcUrl,PG::getUsername,PG::getPassword);
        registry.add("uten.storage.local-dir",()->attachments.toString());
        registry.add("uten.bootstrap.admin-login",()->FullChainEndToEndTest.SHARED_ADMIN_LOGIN);
        registry.add("uten.bootstrap.admin-password",()->FullChainEndToEndTest.SHARED_ADMIN_PASSWORD);
        registry.add("uten.jwt.secret",()->FullChainEndToEndTest.SHARED_JWT_SECRET);
        registry.add("uten.crypto.pgp-master-key",()->FullChainEndToEndTest.SHARED_PGP_KEY);
        registry.add("uten.crypto.hmac-key",()->FullChainEndToEndTest.SHARED_HMAC_KEY);
    }
    @Autowired JdbcTemplate jdbc;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired InventoryValueWorkService worker;
    @Autowired InventoryProductionCostPort production;
    @AfterEach void clearActor(){SecurityContextHolder.clearContext();}
    // Spring closes the dirtied context before Testcontainers' session reaper
    // removes this class-owned database. Do not close a cached context manually.

    @Test void sameConfirmedDocumentResumesItsOriginalRootWithoutRepricingOrInventingSourceFacts() throws Exception {
        HistoricalOrmMappings.requireOriginalSchema(jdbc,1065);
        HistoricalInventoryPlanningSql.requireOriginalPlanningSchema(jdbc);
        try(var choices=BusinessPrecisionContext.use(Map.of())){
            var scenario=new MakePublicSupplyEndToEndTest();beans.autowireBean(scenario);scenario.prepare();
            Set<UUID> existing=new HashSet<>(jdbc.queryForList("SELECT execution_segment_id FROM stock_value_production_cost_objects",UUID.class));
            AssertionError old=assertThrows(AssertionError.class,
                    scenario::aggregatePublicPromiseReceivesItsOwnExactStockAndReversalRestoresOnlyThePromise);
            assertTrue(old.getMessage().startsWith("Inventory-value work remained pending for fixture goods after 45 seconds:"),old::getMessage);
            List<UUID> added=jdbc.queryForList("SELECT execution_segment_id FROM stock_value_production_cost_objects",UUID.class).stream()
                    .filter(scope->!existing.contains(scope)).toList();
            assertEquals(1,added.size());UUID scope=added.getFirst();
            Map<String,Object> before=object(scope);UUID root=(UUID)before.get("precision_origin_id");
            assertEquals(Boolean.TRUE,before.get("business_refresh_pending"));
            assertNull(before.get("business_refresh_precision_root_id"));
            assertEquals(Boolean.FALSE,before.get("precision_closure_complete"));
            assertEquals(0,pendingValueTasks());
            assertEquals(0,worker.runBatch(),"The real old worker is stuck despite every old value task being applied");
            // Compare complete persisted contents, including PostgreSQL arrays;
            // PgArray itself uses Java object identity rather than array equality.
            String original=jdbc.queryForObject("SELECT to_jsonb(revision)::text FROM stock_value_production_cost_revisions revision WHERE id=?",String.class,root);
            List<Map<String,Object>> inputs=inputs(scope);
            List<UUID> goods=jdbc.queryForList("""
                    SELECT DISTINCT pool.goods_id FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id
                    WHERE node.id IN(SELECT unnest(precision_closure_nodes) FROM stock_value_production_cost_objects WHERE execution_segment_id=?)
                    """,UUID.class,scope);
            InventoryValueWorkTestSupport.withRefreshClaim(jdbc,scope,()->{
                TestFlyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword())
                        .locations("classpath:db/migration").target("1066").load().migrate();
                assertEquals(root,jdbc.queryForObject("SELECT fn_inventory_value_output_refresh_continuation(?)",UUID.class,scope));
                assertEquals(scope,jdbc.queryForObject("SELECT fn_inventory_value_root_next_refresh(?)",UUID.class,root));
                try {rejectUnprovedCopies(scope,root);} catch(Exception error){throw new AssertionError(error);}
                return null;
            });
            InventoryValueWorkTestSupport.drain(worker,jdbc,goods);
            Map<String,Object> after=object(scope);
            assertEquals(Boolean.FALSE,after.get("business_refresh_pending"));
            assertEquals(Boolean.TRUE,after.get("precision_closure_complete"));
            assertEquals(root,after.get("precision_origin_id"));
            assertEquals(root,after.get("business_refresh_precision_root_id"));
            for(String field:List.of("business_refresh_event_id","business_refresh_actor_id","business_refresh_precision_policy"))
                assertEquals(before.get(field),after.get(field),field);
            assertEquals(original,jdbc.queryForObject("SELECT to_jsonb(revision)::text FROM stock_value_production_cost_revisions revision WHERE id=?",String.class,root));
            assertEquals(inputs,inputs(scope),"No original input may be replaced, relabelled or repriced");
            var position=production.position(scope);
            assertEquals(0,position.actualKnownCostLocal().compareTo(position.allocatedToOutputsLocal()));
            assertEquals(0,position.heldWipLocal().signum());
            // Run the whole original scenario on fresh real facts after upgrade,
            // retaining its warehouse quantities, adoption, reversal and no-replay assertions.
            scenario.prepare();scenario.aggregatePublicPromiseReceivesItsOwnExactStockAndReversalRestoresOnlyThePromise();
        }
    }

    private Map<String,Object> object(UUID scope){return jdbc.queryForMap("SELECT * FROM stock_value_production_cost_objects WHERE execution_segment_id=?",scope);}
    private List<Map<String,Object>> inputs(UUID scope){return jdbc.queryForList("""
            SELECT input.input_node_id,input.execution_segment_id,input.approved_posting_id,input.input_kind,
              node.quantity_basis,node.range_from,node.range_to,node.initial_known_value,node.initial_pending
            FROM stock_value_production_cost_inputs input JOIN stock_value_nodes node ON node.id=input.input_node_id
            WHERE input.execution_segment_id=? ORDER BY input.input_node_id
            """,scope);}
    private long pendingValueTasks(){return jdbc.queryForObject("""
            SELECT (SELECT count(*) FROM stock_value_production_cost_tasks WHERE status='PENDING')
              +(SELECT count(*) FROM stock_value_tasks WHERE status='PENDING')
              +(SELECT count(*) FROM stock_value_jobs WHERE status<>'APPLIED')
            """,Long.class);}

    private void rejectUnprovedCopies(UUID scope,UUID expected) throws Exception {
        try(Connection connection=jdbc.getDataSource().getConnection()){
            connection.setAutoCommit(false);
            try {
                String schema="iv_cont_oracle_"+UUID.randomUUID().toString().replace("-","");
                assertTrue(schema.matches("[a-z][a-z0-9_]{0,62}"));String quoted='"'+schema+'"';
                execute(connection,"CREATE SCHEMA "+quoted);execute(connection,"SET LOCAL search_path TO "+quoted+",pg_catalog");
                MigratedProjectionSchema.copyTablesWithDataFromMigratedCatalog(connection,
                        "stock_value_production_cost_objects","stock_value_production_cost_revisions","stock_value_production_cost_outputs",
                        "stock_value_events","stock_documents","production_finished_in_confirmations","stock_value_tasks","stock_value_edges",
                        "stock_value_jobs","stock_value_production_cost_tasks","stock_value_production_cost_dirty");
                for(String name:List.of("fn_inventory_value_root_nodes","fn_inventory_value_root_incomplete","fn_inventory_value_output_refresh_continuation")){
                    String definition=(String)scalar(connection,"SELECT pg_get_functiondef(CAST(? AS regprocedure))","public."+name+"(uuid)");
                    String header="CREATE OR REPLACE FUNCTION public."+name+"(";
                    assertTrue(definition.startsWith(header));assertFalse(definition.substring(header.length()).contains("public."),"Oracle cannot escape to public facts");
                    execute(connection,definition.replace(header,"CREATE OR REPLACE FUNCTION "+quoted+"."+name+"("));
                }
                assertEquals(expected,derived(connection,scope));
                Map<String,String> corruptions=new LinkedHashMap<>();
                corruptions.put("actor","UPDATE stock_value_production_cost_objects SET business_refresh_actor_id=gen_random_uuid()");
                corruptions.put("policy","UPDATE stock_value_production_cost_objects SET business_refresh_precision_policy=jsonb_build_object('version',1,'choices',jsonb_build_object('stock.value.interval',jsonb_build_object('scale',4,'rounding','HALF_UP')))");
                corruptions.put("protocol","UPDATE stock_value_production_cost_objects SET business_refresh_precision_version=1");
                corruptions.put("revision-version","UPDATE stock_value_production_cost_objects SET version=version+1");
                corruptions.put("source-version","UPDATE stock_value_events SET source_version=source_version+1 WHERE movement_id=(SELECT business_refresh_event_id FROM stock_value_production_cost_objects WHERE execution_segment_id=?)");
                corruptions.put("source-document","UPDATE stock_value_events SET source_doc_id=gen_random_uuid() WHERE movement_id=(SELECT business_refresh_event_id FROM stock_value_production_cost_objects WHERE execution_segment_id=?)");
                corruptions.put("source-actor","UPDATE stock_value_events SET actor_user_id=gen_random_uuid() WHERE movement_id=(SELECT business_refresh_event_id FROM stock_value_production_cost_objects WHERE execution_segment_id=?)");
                corruptions.put("node-provenance","UPDATE stock_value_events SET result_node_id=(SELECT node FROM stock_value_production_cost_objects object CROSS JOIN LATERAL unnest(object.precision_closure_nodes) node WHERE object.execution_segment_id=? AND node NOT IN(SELECT source_node_id FROM stock_value_production_cost_outputs) LIMIT 1) WHERE movement_id=(SELECT business_refresh_event_id FROM stock_value_production_cost_objects WHERE execution_segment_id=?)");
                corruptions.put("scope-as-root","UPDATE stock_value_production_cost_objects SET precision_origin_id=execution_segment_id");
                corruptions.put("closure","UPDATE stock_value_production_cost_objects object SET precision_closure_nodes=array_remove(precision_closure_nodes,(SELECT source_node_id FROM stock_value_production_cost_outputs output WHERE output.movement_id=object.business_refresh_event_id))");
                corruptions.put("forecast","UPDATE stock_value_production_cost_objects SET precision_forecast_hash=NULL");
                corruptions.put("producer-pending","UPDATE stock_value_production_cost_tasks SET status='PENDING'");
                corruptions.put("stock-pending","UPDATE stock_value_tasks SET status='PENDING'");
                corruptions.put("job-pending","UPDATE stock_value_jobs SET status='PENDING'");
                for(var corruption:corruptions.entrySet()){
                    Savepoint save=connection.setSavepoint();
                    if(corruption.getKey().equals("node-provenance"))execute(connection,corruption.getValue(),scope,scope);
                    else if(corruption.getValue().contains("?"))execute(connection,corruption.getValue(),scope);
                    else execute(connection,corruption.getValue());
                    assertNull(derived(connection,scope),corruption.getKey());connection.rollback(save);
                }
            } finally {connection.rollback();}
        }
    }
    private static UUID derived(Connection connection,UUID scope)throws Exception{return (UUID)scalar(connection,"SELECT fn_inventory_value_output_refresh_continuation(?)",scope);}
    private static Object scalar(Connection connection,String sql,Object... values)throws Exception{
        try(var query=connection.prepareStatement(sql)){for(int i=0;i<values.length;i++)query.setObject(i+1,values[i]);
            try(var rows=query.executeQuery()){assertTrue(rows.next());return rows.getObject(1);}}
    }
    private static void execute(Connection connection,String sql)throws Exception{try(var statement=connection.createStatement()){statement.execute(sql);}}
    private static void execute(Connection connection,String sql,Object... values)throws Exception{
        try(var statement=connection.prepareStatement(sql)) {
            for(int i=0;i<values.length;i++) { statement.setObject(i+1,values[i]); }
            statement.execute();
        }
    }
}
