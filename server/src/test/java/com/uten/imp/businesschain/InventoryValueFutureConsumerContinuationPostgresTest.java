package com.uten.imp.businesschain;

import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.allocation.ProductionMaterialAllocationFacade;
import com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService;
import com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService;
import com.uten.imp.features.stock.valuation.InventoryValueWorkService;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.sql.Connection;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;

/** Forward proof over original report facts; a future consumer's dirty revision is retained. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "spring.jpa.mapping-resources="+HistoricalOrmMappings.BEFORE_V1113,
        HistoricalInventoryPlanningSql.PROPERTY,
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only"})
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
class InventoryValueFutureConsumerContinuationPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("uten_imp").withUsername("fixture_admin").withPassword("uten")
            .withCommand("postgres","-c","max_connections=400");
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry)throws Exception{
        PG.start();FixtureDatabaseProperties.bindSameRole(registry,PG::getJdbcUrl,PG::getUsername,PG::getPassword);
        registry.add("spring.flyway.target",()->"1099");
        var attachments=Files.createTempDirectory("uten-future-consumer-");
        registry.add("uten.storage.local-dir",attachments::toString);
        registry.add("uten.bootstrap.admin-login",()->FullChainEndToEndTest.SHARED_ADMIN_LOGIN);
        registry.add("uten.bootstrap.admin-password",()->FullChainEndToEndTest.SHARED_ADMIN_PASSWORD);
        registry.add("uten.jwt.secret",()->FullChainEndToEndTest.SHARED_JWT_SECRET);
        registry.add("uten.crypto.pgp-master-key",()->FullChainEndToEndTest.SHARED_PGP_KEY);
        registry.add("uten.crypto.hmac-key",()->FullChainEndToEndTest.SHARED_HMAC_KEY);
    }
    @Autowired JdbcTemplate jdbc;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired InventoryValueWorkService worker;
    @Autowired StockDocService stock;
    @Autowired ProductionExecutionReadinessService readiness;
    @Autowired ProductionPlanMutationFootprintService footprints;
    @Autowired ProductionMaterialAllocationFacade allocation;
    @AfterEach void clearActor(){SecurityContextHolder.clearContext();}

    @Test void futureDirtyCannotSelfBlockTheOriginalRootButAnActivePlanStillBlocks()throws Exception{
        HistoricalOrmMappings.requireOriginalSchema(jdbc,1099);
        HistoricalInventoryPlanningSql.requireOriginalPlanningSchema(jdbc);
        // Retained-record reads consult the V1120 registry while this chain stays
        // at V1099; install the real read-side table and lookup function from the
        // same current migrated catalog rejectActiveDirty copies below.
        MigratedProjectionSchema.createCurrentTables(jdbc,"imported_document_registry");
        MigratedProjectionSchema.createCurrentFunctions(jdbc,"fn_imported_business_document_registered");
        // 644e78496 起生产代码调 V1129 的两个函数，本链库停在迁移前历史版本。桩忠实
        // 再现 V1129 语义(可报余量=MIN(净发料/单耗)-未清账已报，capacity>=计划量时
        // NULL 回计划量口径；证明落库为否)，只依赖本链历史版本已有的列。
        jdbc.execute("""
                CREATE OR REPLACE FUNCTION fn_execution_partial_material_report_room(p_segment uuid,p_exclude uuid DEFAULT NULL)
                RETURNS numeric LANGUAGE sql STABLE AS $$
                WITH dem AS MATERIALIZED (
                  SELECT demand.per_product_qty, COALESCE(net.net_qty,0) AS net_qty
                  FROM production_material_demands demand
                  LEFT JOIN LATERAL (
                    SELECT SUM(CASE posting.posting_type WHEN 'ISSUE' THEN posting.qty_base
                               WHEN 'GOOD_RETURN_REVERSE' THEN posting.qty_base ELSE -posting.qty_base END) AS net_qty
                    FROM production_material_stock_postings posting WHERE posting.demand_id=demand.id) net ON TRUE
                  WHERE demand.execution_segment_id=p_segment AND NOT demand.is_deleted
                    AND demand.material_increment_request_id IS NULL AND demand.status NOT IN('RELEASED','REVERSED')),
                room AS MATERIALIZED (SELECT COALESCE(MIN(net_qty/NULLIF(per_product_qty,0)),0) AS cap FROM dem)
                SELECT CASE
                  WHEN NOT EXISTS(SELECT 1 FROM production_execution_segments s WHERE s.id=p_segment AND NOT s.is_deleted) THEN 0
                  WHEN room.cap>=segment.planned_qty THEN NULL
                  ELSE GREATEST(room.cap-(SELECT COALESCE(SUM(item.qty),0) FROM production_daily_report_items item
                      JOIN production_daily_reports report ON report.id=item.report_id
                      WHERE item.execution_segment_id=p_segment AND item.fqc_recovery_authorization_id IS NULL
                        AND NOT item.is_deleted AND NOT report.is_deleted AND report.status IN (0,1)
                        AND (p_exclude IS NULL OR report.id<>p_exclude)),0) END
                FROM production_execution_segments segment CROSS JOIN room
                WHERE segment.id=p_segment AND NOT segment.is_deleted
                $$;
                CREATE OR REPLACE FUNCTION fn_capture_execution_full_material_kit(uuid) RETURNS boolean LANGUAGE sql AS 'SELECT FALSE';
                """);
        var scenario=scenario();
        AssertionError original=assertThrows(AssertionError.class,scenario::allDirectChildrenStartAtOnceAndEachTransferTopsUpTheRunningParent);
        assertTrue(original.getMessage().startsWith("Inventory-value work remained pending for fixture goods after 45 seconds:"),original::getMessage);
        List<UUID> scopes=jdbc.queryForList("""
                SELECT execution_segment_id FROM stock_value_production_cost_objects
                WHERE business_refresh_pending AND business_refresh_precision_root_id IS NULL
                  AND precision_closure_pending AND NOT precision_closure_complete
                """,UUID.class);
        assertEquals(1,scopes.size());UUID scope=scopes.getFirst();var before=object(scope);
        UUID root=(UUID)before.get("precision_origin_id");long version=((Number)before.get("version")).longValue();
        assertEquals(0,pendingTasks());assertEquals(0,worker.runBatch());
        assertFalse(jdbc.queryForObject("SELECT fn_inventory_value_continuation_work_applied(precision_closure_nodes) FROM stock_value_production_cost_objects WHERE execution_segment_id=?",Boolean.class,scope));
        assertTrue(futureDirty()>0,"The pending source belongs to a real future consumer with no current plan");
        String revisions=originalRevisions(scope,version);
        String oldWork=function("fn_inventory_value_continuation_work_applied(uuid[])");
        String oldOutput=function("fn_inventory_value_output_refresh_continuation(uuid)");
        String migration;
        try(var input=getClass().getResourceAsStream("/db/migration/V1100__inventory_value_actionable_consumer_continuation.sql")){
            migration=new String(Objects.requireNonNull(input).readAllBytes(),StandardCharsets.UTF_8);
        }
        try(Connection connection=jdbc.getDataSource().getConnection()){
            connection.setAutoCommit(false);
            try{
                execute(connection,migration);
                assertEquals(root,scalar(connection,"SELECT fn_inventory_value_direct_report_refresh_continuation(?)",scope));
                assertEquals(scope,scalar(connection,"SELECT fn_inventory_value_root_next_refresh(?)",root));
                String replaced=(String)scalar(connection,"SELECT pg_get_functiondef('fn_inventory_value_output_refresh_continuation(uuid)'::regprocedure)");
                assertEquals(oldOutput.substring(0,oldOutput.indexOf("   AND NOT EXISTS(SELECT 1 FROM stock_value_tasks")),
                        replaced.substring(0,replaced.indexOf("   AND fn_inventory_value_continuation_work_applied")),
                        "All same-document owner/actor/policy/version/closure clauses stay byte-for-byte");
            }finally{connection.rollback();}
        }
        assertEquals(oldWork,function("fn_inventory_value_continuation_work_applied(uuid[])"));
        assertEquals(oldOutput,function("fn_inventory_value_output_refresh_continuation(uuid)"));
        assertEquals(revisions,originalRevisions(scope,version));
        TestFlyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword())
                .locations("classpath:db/migration").target("1100").load().migrate();
        assertEquals(root,jdbc.queryForObject("SELECT fn_inventory_value_direct_report_refresh_continuation(?)",UUID.class,scope));
        // Reuse the existing isolated real-catalog oracle for every actor,
        // policy, generation, closure and pending-task counterfeit boundary.
        var proofs=new InventoryValueDirectReportRefreshContinuationPostgresTest();beans.autowireBean(proofs);
        ReflectionTestUtils.invokeMethod(proofs,"rejectUnprovedCopies",List.of(scope),Map.of(scope,before));
        rejectActiveDirty(scope);
        var goods=jdbc.queryForList("SELECT DISTINCT goods_id FROM stock_value_pools",UUID.class);
        InventoryValueWorkTestSupport.drain(worker,jdbc,goods);
        var after=object(scope);assertFalse((Boolean)after.get("business_refresh_pending"));
        assertTrue((Boolean)after.get("precision_closure_complete"));
        assertEquals(root,after.get("precision_origin_id"));assertEquals(revisions,originalRevisions(scope,version));
        assertTrue(futureDirty()>0,"The future source revision is retained for its first real plan");
        // Run the complete original scenario and its unchanged quantity,
        // ownership, final-report and reporting-limit assertions on fresh facts.
        scenario=scenario();scenario.allDirectChildrenStartAtOnceAndEachTransferTopsUpTheRunningParent();
        InventoryValueWorkTestSupport.drain(worker,jdbc,jdbc.queryForList("SELECT DISTINCT goods_id FROM stock_value_pools",UUID.class));
    }

    private WorkshopContinuousSupplyEndToEndTest scenario(){
        var scenario=new WorkshopContinuousSupplyEndToEndTest();beans.autowireBean(scenario);
        scenario.stock=stock;scenario.readiness=readiness;scenario.planFootprints=footprints;scenario.allocation=allocation;
        scenario.prepare();return scenario;
    }
    private long futureDirty(){return jdbc.queryForObject("""
            SELECT count(*) FROM stock_value_production_cost_dirty dirty
            LEFT JOIN stock_value_production_cost_objects object USING(execution_segment_id)
            WHERE dirty.observed_revision>dirty.cleared_revision AND object.current_revision_id IS NULL
            """,Long.class);}
    private long pendingTasks(){return jdbc.queryForObject("""
            SELECT (SELECT count(*) FROM stock_value_tasks WHERE status='PENDING')
                +(SELECT count(*) FROM stock_value_production_cost_tasks WHERE status='PENDING')
                +(SELECT count(*) FROM stock_value_jobs WHERE status<>'APPLIED')
            """,Long.class);}
    private Map<String,Object> object(UUID scope){return jdbc.queryForMap("SELECT * FROM stock_value_production_cost_objects WHERE execution_segment_id=?",scope);}
    private String function(String signature){return jdbc.queryForObject("SELECT pg_get_functiondef(CAST(? AS regprocedure))",String.class,signature);}
    private String originalRevisions(UUID scope,long version){return jdbc.queryForObject("""
            SELECT jsonb_agg(to_jsonb(revision) ORDER BY version)::text
            FROM stock_value_production_cost_revisions revision WHERE execution_segment_id=? AND version<=?
            """,String.class,scope,version);}

    private void rejectActiveDirty(UUID scope)throws Exception{
        try(Connection connection=jdbc.getDataSource().getConnection()){
            connection.setAutoCommit(false);
            try{
                String schema="iv_active_dirty_"+UUID.randomUUID().toString().replace("-","");
                assertTrue(schema.matches("[a-z][a-z0-9_]{0,62}"));String quoted='"'+schema+'"';
                execute(connection,"CREATE SCHEMA "+quoted);execute(connection,"SET LOCAL search_path TO "+quoted+",pg_catalog");
                MigratedProjectionSchema.copyTablesWithDataFromMigratedCatalog(connection,
                        "stock_value_tasks","stock_value_edges","stock_value_jobs","stock_value_production_cost_tasks",
                        "stock_value_production_cost_objects",
                        "stock_value_production_cost_inputs","stock_value_nodes","stock_value_node_revisions");
                MigratedProjectionSchema.copyConstrainedTablesFromMigratedCatalog(connection,"stock_value_production_cost_dirty");
                execute(connection,"INSERT INTO stock_value_production_cost_dirty SELECT * FROM public.stock_value_production_cost_dirty");
                String definition=function("fn_inventory_value_continuation_work_applied(uuid[])");
                String header="CREATE OR REPLACE FUNCTION public.fn_inventory_value_continuation_work_applied(";
                assertTrue(definition.startsWith(header));assertFalse(definition.substring(header.length()).contains("public."));
                execute(connection,definition.replace(header,"CREATE OR REPLACE FUNCTION "+quoted+".fn_inventory_value_continuation_work_applied("));
                String nodes=(String)scalar(connection,"SELECT precision_closure_nodes::text FROM stock_value_production_cost_objects WHERE execution_segment_id=?",scope);
                assertEquals(Boolean.TRUE,scalar(connection,"SELECT fn_inventory_value_continuation_work_applied(CAST(? AS uuid[]))",nodes));
                // Re-open an actual recorded source revision for an actual input
                // of this real current plan, only in the rollback-only copy.
                try(var statement=connection.prepareStatement("""
                        INSERT INTO stock_value_production_cost_dirty(execution_segment_id,input_node_id,observed_revision,cleared_revision,source_event_id)
                        SELECT input.execution_segment_id,node.id,node.revision,0,COALESCE(revision.event_id,node.creation_event_id)
                        FROM stock_value_production_cost_inputs input JOIN stock_value_nodes node ON node.id=input.input_node_id
                        LEFT JOIN stock_value_node_revisions revision ON revision.node_id=node.id AND revision.revision=node.revision
                        WHERE input.execution_segment_id=? ORDER BY node.id LIMIT 1
                        ON CONFLICT(input_node_id) DO UPDATE SET execution_segment_id=EXCLUDED.execution_segment_id,
                            observed_revision=EXCLUDED.observed_revision,
                            cleared_revision=0,source_event_id=EXCLUDED.source_event_id
                        """)){
                    statement.setObject(1,scope);assertEquals(1,statement.executeUpdate());
                }
                assertEquals(Boolean.FALSE,scalar(connection,"SELECT fn_inventory_value_continuation_work_applied(CAST(? AS uuid[]))",nodes),
                        "An actual active-plan input revision still blocks the whole continuation");
            }finally{connection.rollback();}
        }
    }
    private static Object scalar(Connection connection,String sql,Object... values)throws Exception{
        try(var query=connection.prepareStatement(sql)){
            for(int index=0;index<values.length;index++)query.setObject(index+1,values[index]);
            try(var result=query.executeQuery()){assertTrue(result.next());return result.getObject(1);}
        }
    }
    private static void execute(Connection connection,String sql)throws Exception{try(var statement=connection.createStatement()){statement.execute(sql);}}
}
