package com.uten.imp.businesschain;

import com.uten.imp.features.stock.valuation.InventoryValueWorkService;
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

/** Real V1071 reports, unchanged worker deadline, forward upgrade and original assertions. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","spring.flyway.target=1071",
        "spring.jpa.mapping-resources="+HistoricalOrmMappings.BEFORE_V1097,
        HistoricalInventoryPlanningSql.BEFORE_V1097_PROPERTY,
        "uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.read-summary.compaction-enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only"})
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
class InventoryValueDirectReportRefreshContinuationPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("uten_imp").withUsername("fixture_admin").withPassword("uten")
            .withCommand("postgres","-c","max_connections=400");
    private static Path attachments;
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry)throws Exception {
        PG.start();attachments=Files.createTempDirectory("uten-direct-value-continuation-");
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
    @AfterEach void clearActor(){SecurityContextHolder.clearContext();}

    @Test void exactReportGenerationResumesBothPhysicalAndConsumptionRootsWithoutRewritingHistory()throws Exception {
        HistoricalOrmMappings.requireOriginalSchema(jdbc,1071);
        HistoricalInventoryPlanningSql.requireOriginalPlanningSchema(jdbc);
        var scenario=new AggregateMaterialDirectTransferEndToEndTest();beans.autowireBean(scenario);
        scenario.before();
        UUID consumption=failedScope(scenario::sharedChildActuallyHandsOverToEachOriginalParentWithinOneMemberShare);
        scenario.before();
        UUID physical=failedScope(scenario::mixedWorkshopParentsGetTheirShareDirectAndOnlyTheCrossWorkshopShareGoesToTheWarehouse);
        List<UUID> scopes=List.of(consumption,physical);
        Map<UUID,Map<String,Object>> before=new LinkedHashMap<>();
        Map<UUID,String> revisions=new LinkedHashMap<>();
        Map<UUID,List<Map<String,Object>>> inputs=new LinkedHashMap<>();
        Set<UUID> goods=new LinkedHashSet<>();
        String oldProof=jdbc.queryForObject("SELECT pg_get_functiondef('fn_inventory_value_output_refresh_continuation(uuid)'::regprocedure)",String.class);
        String oldGraphBody=jdbc.queryForObject("SELECT prosrc FROM pg_proc WHERE oid='fn_inventory_value_precision_scope(uuid[])'::regprocedure",String.class);
        for(UUID scope:scopes){
            var object=object(scope);before.put(scope,object);
            assertTrue((Boolean)object.get("business_refresh_pending"));
            assertNull(object.get("business_refresh_precision_root_id"));
            assertFalse((Boolean)object.get("precision_closure_complete"));
            assertNull(jdbc.queryForObject("SELECT fn_inventory_value_output_refresh_continuation(?)",UUID.class,scope));
            assertTrue(jdbc.queryForObject("SELECT fn_inventory_value_production_inputs_ready(?)",Boolean.class,scope));
            revisions.put(scope,originalRevisions(scope));inputs.put(scope,originalInputs(scope));
            goods.addAll(jdbc.queryForList("""
                    SELECT DISTINCT pool.goods_id FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id
                    WHERE node.id IN(SELECT unnest(precision_closure_nodes) FROM stock_value_production_cost_objects WHERE execution_segment_id=?)
                    """,UUID.class,scope));
        }
        assertEquals(0,pendingTasks());
        assertEquals(0,worker.runBatch(),"V1071 is stuck even after every old task has actually applied");
        InventoryValueWorkTestSupport.withRefreshClaim(jdbc,consumption,()->
            InventoryValueWorkTestSupport.withRefreshClaim(jdbc,physical,()->{
                TestFlyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword())
                        .locations("classpath:db/migration").target("1072").load().migrate();
                assertEquals(oldProof,jdbc.queryForObject("SELECT pg_get_functiondef('fn_inventory_value_output_refresh_continuation(uuid)'::regprocedure)",String.class));
                assertEquals(oldGraphBody,jdbc.queryForObject("SELECT prosrc FROM pg_proc WHERE oid='fn_inventory_value_precision_scope(uuid[])'::regprocedure",String.class));
                for(UUID scope:scopes){
                    UUID root=(UUID)before.get(scope).get("precision_origin_id");
                    assertNull(jdbc.queryForObject("SELECT fn_inventory_value_output_refresh_continuation(?)",UUID.class,scope),"The old same-document proof keeps its exact boundary");
                    try(Connection connection=jdbc.getDataSource().getConnection()){
                        Object originalJit=scalar(connection,"SELECT current_setting('jit')");
                        assertEquals(root,scalar(connection,"SELECT fn_inventory_value_direct_report_refresh_continuation(?)",scope));
                        assertEquals(root,scalar(connection,"SELECT fn_inventory_value_business_refresh_continuation(?)",scope));
                        assertEquals(originalJit,scalar(connection,"SELECT current_setting('jit')"),
                                "The repeated proof cannot change its caller's execution settings");
                    }catch(Exception error){throw new AssertionError(error);}
                    assertEquals(scope,jdbc.queryForObject("SELECT fn_inventory_value_root_next_refresh(?)",UUID.class,root));
                }
                try{rejectUnprovedCopies(scopes,before);}catch(Exception error){throw new AssertionError(error);}
                return null;
            }));
        drainWithinBudget(List.copyOf(goods));
        for(UUID scope:scopes){
            var original=before.get(scope);var after=object(scope);
            assertFalse((Boolean)after.get("business_refresh_pending"));
            assertTrue((Boolean)after.get("precision_closure_complete"));
            assertEquals(original.get("precision_origin_id"),after.get("precision_origin_id"));
            assertEquals(original.get("precision_origin_id"),after.get("business_refresh_precision_root_id"));
            for(String field:List.of("business_refresh_event_id","business_refresh_actor_id","business_refresh_precision_policy")){
                assertEquals(original.get(field),after.get(field),field);
            }
            assertEquals(revisions.get(scope),originalRevisionsThrough(scope,((Number)original.get("version")).longValue()),"Every original plan remains byte-for-byte unchanged");
            assertEquals(inputs.get(scope),originalInputs(scope),"Original input identity, quantities and monetary operand points cannot be relabelled");
        }
        // Original routing, shares, warehouse accounting, cancellation and replay
        // assertions all run again on fresh real facts after the forward upgrade.
        scenario.before();scenario.sharedChildActuallyHandsOverToEachOriginalParentWithinOneMemberShare();
        scenario.before();scenario.mixedWorkshopParentsGetTheirShareDirectAndOnlyTheCrossWorkshopShareGoesToTheWarehouse();
        // The original scenarios leave their last physical output asynchronous.
        // Verify those real live queues too, including work from earlier worlds.
        drainWithinBudget(jdbc.queryForList("SELECT DISTINCT goods_id FROM stock_value_pools",UUID.class));
        assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM stock_value_production_cost_objects WHERE business_refresh_pending OR precision_closure_pending AND NOT precision_closure_complete",Integer.class));
    }

    private void drainWithinBudget(List<UUID> goods){
        long started=System.nanoTime();
        InventoryValueWorkTestSupport.drain(worker,jdbc,goods);
        assertTrue(System.nanoTime()-started<=java.time.Duration.ofSeconds(45).toNanos(),
                "Actual original-root and live-queue closure must stay inside the unchanged 45-second worker budget");
    }

    private UUID failedScope(org.junit.jupiter.api.function.Executable operation){
        Set<UUID> existing=new HashSet<>(jdbc.queryForList("SELECT execution_segment_id FROM stock_value_production_cost_objects",UUID.class));
        AssertionError failure=assertThrows(AssertionError.class,operation);
        assertTrue(failure.getMessage().startsWith("Inventory-value work remained pending for fixture goods after 45 seconds:"),failure::getMessage);
        List<UUID> scopes=jdbc.queryForList("""
                SELECT execution_segment_id FROM stock_value_production_cost_objects
                WHERE business_refresh_pending AND business_refresh_precision_root_id IS NULL
                  AND precision_closure_pending AND NOT precision_closure_complete
                """,UUID.class).stream().filter(scope->!existing.contains(scope)).toList();
        assertEquals(1,scopes.size());return scopes.getFirst();
    }
    private Map<String,Object> object(UUID scope){return jdbc.queryForMap("SELECT * FROM stock_value_production_cost_objects WHERE execution_segment_id=?",scope);}
    private String originalRevisions(UUID scope){return originalRevisionsThrough(scope,Long.MAX_VALUE);}
    private String originalRevisionsThrough(UUID scope,long version){return jdbc.queryForObject("""
            SELECT jsonb_agg(to_jsonb(revision) ORDER BY version)::text FROM stock_value_production_cost_revisions revision
            WHERE execution_segment_id=? AND version<=?
            """,String.class,scope,version);}
    private List<Map<String,Object>> originalInputs(UUID scope){return jdbc.queryForList("""
            SELECT input.input_node_id,input.execution_segment_id,input.approved_posting_id,input.input_kind,
              node.quantity_basis,node.range_from,node.range_to,node.initial_known_value,node.initial_pending
            FROM stock_value_production_cost_inputs input JOIN stock_value_nodes node ON node.id=input.input_node_id
            WHERE input.execution_segment_id=? ORDER BY input.input_node_id
            """,scope);}
    private long pendingTasks(){return jdbc.queryForObject("""
            SELECT (SELECT count(*) FROM stock_value_production_cost_tasks WHERE status='PENDING')
              +(SELECT count(*) FROM stock_value_tasks WHERE status='PENDING')
              +(SELECT count(*) FROM stock_value_jobs WHERE status<>'APPLIED')
            """,Long.class);}

    private void rejectUnprovedCopies(List<UUID> scopes,Map<UUID,Map<String,Object>> before)throws Exception {
        try(Connection connection=jdbc.getDataSource().getConnection()){
            connection.setAutoCommit(false);
            try{
                String schema="iv_direct_oracle_"+UUID.randomUUID().toString().replace("-","");
                assertTrue(schema.matches("[a-z][a-z0-9_]{0,62}"));String quoted='"'+schema+'"';
                execute(connection,"CREATE SCHEMA "+quoted);execute(connection,"SET LOCAL search_path TO "+quoted+",pg_catalog");
                String[] viewTables={"production_material_demands","production_material_settlement_postings","stock_value_events",
                        "stock_value_nodes","stock_value_pools","workshop_material_close_allocations","workshop_material_close_materials","workshop_material_period_closes"};
                MigratedProjectionSchema.copyTablesWithDataFromMigratedCatalog(connection,viewTables);
                MigratedProjectionSchema.copyTablesWithDataFromMigratedCatalog(connection,
                        "stock_value_production_cost_objects","stock_value_production_cost_revisions","stock_value_production_cost_outputs",
                        "stock_value_production_cost_inputs","stock_movements","stock_document_items","stock_documents",
                        "production_daily_reports","production_daily_report_items","production_daily_report_commands",
                        "production_workshop_direct_transfer_items","production_workshop_direct_transfers",
                        "production_fqc_inspections","production_fqc_release_commands","production_fqc_release_allocations",
                        "production_fqc_decision_events","production_finished_in_confirmations","production_fqc_cancellation_events",
                        "production_material_settlement_events","stock_value_tasks","stock_value_edges","stock_value_jobs",
                        "stock_value_production_cost_tasks","stock_value_production_cost_dirty",
                        "production_execution_segments","production_execution_segment_splits","production_actual_output_supplement_proofs");
                MigratedProjectionSchema.copyReadViewFromMigratedCatalog(connection,"v_production_cost_input_candidates",viewTables);
                for(String signature:List.of("fn_production_execution_cost_scope(uuid)","fn_inventory_value_precision_key(uuid,uuid)",
                        "fn_inventory_value_root_incomplete(uuid)","fn_inventory_value_precision_successors(uuid)","fn_inventory_value_precision_predecessors(uuid)",
                        "fn_inventory_value_precision_scope(uuid[])","fn_inventory_value_production_input_ancestors(uuid)",
                        "fn_inventory_value_continuation_work_applied(uuid[])","fn_inventory_value_direct_output_owner(uuid,uuid,bigint,uuid,jsonb)","fn_inventory_value_direct_report_refresh_continuation(uuid)")){
                    String definition=(String)scalar(connection,"SELECT pg_get_functiondef(CAST(? AS regprocedure))","public."+signature);
                    String header="CREATE OR REPLACE FUNCTION public."+signature.substring(0,signature.indexOf('('))+"(";
                    assertTrue(definition.startsWith(header));
                    assertFalse(definition.substring(header.length()).contains("public."),"The oracle cannot read live business facts");
                    execute(connection,definition.replace(header,"CREATE OR REPLACE FUNCTION "+quoted+"."+signature.substring(0,signature.indexOf('('))+"("));
                }
                for(UUID scope:scopes){
                    UUID root=(UUID)before.get(scope).get("precision_origin_id");
                    assertEquals(root,derived(connection,scope));
                    Map<String,String> corruptions=new LinkedHashMap<>();
                    corruptions.put("actor","UPDATE stock_value_production_cost_objects SET business_refresh_actor_id=gen_random_uuid() WHERE execution_segment_id=?");
                    corruptions.put("policy","UPDATE stock_value_production_cost_objects SET business_refresh_precision_policy='{}'::jsonb WHERE execution_segment_id=?");
                    corruptions.put("version","UPDATE stock_value_production_cost_objects SET version=version+1 WHERE execution_segment_id=?");
                    corruptions.put("root","UPDATE stock_value_production_cost_objects SET precision_origin_id=execution_segment_id WHERE execution_segment_id=?");
                    corruptions.put("forecast","UPDATE stock_value_production_cost_objects SET precision_forecast_hash=NULL WHERE execution_segment_id=?");
                    corruptions.put("closure","UPDATE stock_value_production_cost_objects SET precision_closure_nodes=ARRAY[]::uuid[] WHERE execution_segment_id=?");
                    corruptions.put("outside-closure","UPDATE stock_value_production_cost_objects SET precision_closure_nodes=array_append(precision_closure_nodes,gen_random_uuid()) WHERE execution_segment_id=?");
                    corruptions.put("ancestor","UPDATE stock_value_production_cost_objects SET precision_input_ancestor_nodes=ARRAY[]::uuid[] WHERE execution_segment_id=?");
                    corruptions.put("keys","UPDATE stock_value_production_cost_objects SET precision_closure_keys=array_append(precision_closure_keys,'outside:-') WHERE execution_segment_id=?");
                    String event=" WHERE movement_id=(SELECT business_refresh_event_id FROM stock_value_production_cost_objects WHERE execution_segment_id=?)";
                    corruptions.put("physical-version","UPDATE stock_value_events SET source_version=source_version+1"+event);
                    corruptions.put("physical-generation","UPDATE stock_value_events SET created_txid=created_txid+1"+event);
                    corruptions.put("physical-actor","UPDATE stock_value_events SET actor_user_id=gen_random_uuid()"+event);
                    corruptions.put("physical-policy","UPDATE stock_value_events SET business_precision_policy='{}'::jsonb"+event);
                    corruptions.put("physical-document","UPDATE stock_value_events SET source_doc_id=gen_random_uuid()"+event);
                    String report=" WHERE report_id=(SELECT doc.source_daily_report_id FROM stock_value_production_cost_objects object JOIN stock_movements movement ON movement.id=object.business_refresh_event_id JOIN stock_documents doc ON doc.id=movement.source_doc_id WHERE object.execution_segment_id=?) AND command_kind='APPROVE'";
                    corruptions.put("approval-actor","UPDATE production_daily_report_commands SET actor_user_id=gen_random_uuid()"+report);
                    corruptions.put("approval-generation","UPDATE production_daily_report_commands SET created_at=created_at+interval '1 second'"+report);
                    corruptions.put("reviewed-version","UPDATE production_daily_report_commands SET approval_protocol_version=2,reviewed_row_version=1000000"+report);
                    corruptions.put("producer-pending","UPDATE stock_value_production_cost_tasks SET status='PENDING' WHERE execution_segment_id=?");
                    corruptions.put("stock-pending","UPDATE stock_value_tasks SET status='PENDING' WHERE edge_id IN(SELECT edge.id FROM stock_value_edges edge JOIN stock_value_production_cost_objects object ON edge.parent_node_id=ANY(object.precision_closure_nodes) OR edge.child_node_id=ANY(object.precision_closure_nodes) WHERE object.execution_segment_id=?)");
                    corruptions.put("job-pending","UPDATE stock_value_jobs SET status='PENDING' WHERE precision_origin_id=(SELECT precision_origin_id FROM stock_value_production_cost_objects WHERE execution_segment_id=?)");
                    for(var corruption:corruptions.entrySet()){
                        Savepoint save=connection.setSavepoint();
                        assertTrue(update(connection,corruption.getValue(),scope)>0,corruption.getKey()+" must corrupt real nonempty facts");
                        assertNull(derived(connection,scope),corruption.getKey());connection.rollback(save);
                    }
                }
            }finally{connection.rollback();}
        }
    }
    private static UUID derived(Connection connection,UUID scope)throws Exception{return (UUID)scalar(connection,"SELECT fn_inventory_value_direct_report_refresh_continuation(?)",scope);}
    private static Object scalar(Connection connection,String sql,Object... values)throws Exception{
        try(var query=connection.prepareStatement(sql)){
            for(int i=0;i<values.length;i++){query.setObject(i+1,values[i]);}
            try(var rows=query.executeQuery()){assertTrue(rows.next());return rows.getObject(1);}
        }
    }
    private static int update(Connection connection,String sql,Object... values)throws Exception{
        try(var query=connection.prepareStatement(sql)){
            for(int i=0;i<values.length;i++){query.setObject(i+1,values[i]);}
            return query.executeUpdate();
        }
    }
    private static void execute(Connection connection,String sql)throws Exception{try(var statement=connection.createStatement()){statement.execute(sql);}}
}
