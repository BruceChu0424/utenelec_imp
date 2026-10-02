package com.uten.imp.businesschain;

import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts.*;
import org.flywaydb.core.Flyway;
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
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.*;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/** Backfill real pre-number requests, then prove online retries/concurrency use
 * the same lifetime number registry without creating a physical stock document. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
    // The schema is pinned at V730 on purpose: entity columns added by later migrations must not be validated here.
    "spring.profiles.active=dev","spring.flyway.target=730","spring.jpa.hibernate.ddl-auto=none",
    "uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
    "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
    "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
    "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
    "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
    "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
    "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionMaterialRequestNumberMigrationPostgresTest {
    private static final PostgreSQLContainer<?> DATABASE=new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("material_request_numbers").withUsername("uten").withPassword("uten");
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){
        DATABASE.start();registry.add("spring.datasource.url",DATABASE::getJdbcUrl);
        registry.add("spring.datasource.username",DATABASE::getUsername);registry.add("spring.datasource.password",DATABASE::getPassword);
        registry.add("uten.storage.local-dir",()->System.getProperty("java.io.tmpdir")+"/material-request-number-"+DATABASE.getContainerId());
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    // V730 has none of these unrelated AI/template retention schemas at Spring startup.
    // Keep the actual sales/learning/stock services real; only background entry points are inert
    // here. Their current-schema worker/profile tests cover their normal behavior separately.
    @MockitoBean(enforceOverride=true)
    com.uten.imp.features.sales.learning.SalesLearningEvidenceCleanupScheduler learningCleanup;
    @MockitoBean(enforceOverride=true)
    com.uten.imp.features.sales.template.SalesQuoteTemplateCleanupScheduler templateCleanup;
    @MockitoBean(enforceOverride=true)
    com.uten.imp.features.ai.provider.AiProviderSecretRewrap providerStartupRewrap;
    @BeforeEach void bridgeCurrentJavaToTheUnmodifiedV730QuantityView(){
        // The fixture intentionally boots V730. Current Java has a V732 reader
        // name; this test-only bridge reads the original view verbatim, adds no
        // request number column and neither changes nor bypasses quantity guards.
        db.execute("""
                CREATE FUNCTION fn_preplan_make_public_supply_sources(p_target_analysis UUID DEFAULT NULL,p_source_plan_item UUID DEFAULT NULL)
                RETURNS SETOF v_preplan_make_public_supply_state LANGUAGE sql STABLE AS $$
                    SELECT source.* FROM v_preplan_make_public_supply_state source
                    WHERE (p_source_plan_item IS NULL OR source.source_plan_item_id=p_source_plan_item)
                      AND (p_target_analysis IS NULL OR EXISTS(SELECT 1 FROM production_material_analyses target
                        JOIN production_material_analysis_materials material ON material.analysis_id=target.id AND material.active
                        WHERE target.id=p_target_analysis AND NOT target.is_deleted
                          AND fn_warehouse_same_main(target.warehouse_id,source.warehouse_id)
                          AND material.goods_id=source.goods_id AND material.color_id IS NOT DISTINCT FROM source.color_id
                          AND material.unit_id=source.unit_id))
                $$
                """);
        // Current Java also reads the ADR-129 BOM usage objects (view, learning, new columns). They are
        // independent of V731, so the same migration is applied here verbatim; found by name because its
        // version number is assigned when it lands.
        var migrationFiles=java.util.Collections.<java.nio.file.Path>emptyList();
        try {
            migrationFiles=java.nio.file.Files.list(java.nio.file.Path.of("src/main/resources/db/migration")).toList();
            // 当前 Java 的实体与查询需要后续迁移给既有表加的列/对象; 与 V731 编号回填互相独立、
            // 且不触碰 V730 库上尚不存在的对象(整段 V733..V743 连放会在跳版本的库上断), 按需逐个
            // verbatim 应用: V739 BOM 用量、V735 draw_batch_no、V740 issue_method/内料仓、
            // V742 AI 列、V743 重量账列、V744 商业扩展列、V748 销售英文名称快照、V752 别名证据、
            // V787 手工出入库单行级仓库(StockDocumentItem ORM 新增 warehouse_id 字段; 其库位
            // 学习约束只动 V431/V451 已存在的 warehouse_goods_place_preferences, 与编号无关)。
            // V744/V748 为当前 SalesOrderItem ORM 的无关新增字段; V752 让实际 afterSave 挂钩
            // 读取空的客户别名证据。三者均不读取或改变物料发现请求、编号注册/序列或数量事实。
            // V731 延后到测试中段单独验证; V732 保持上述旧视图桥。
            for(String suffix:new String[]{"__bom_design_and_actual_usage.sql","__draw_batch_no.sql",
                    "__workshop_material_periodic_costing.sql","__ai_platform_sales_intake_learning.sql",
                    "__warehouse_weight_ledger_and_learning.sql","__business_document_extra_columns.sql",
                    "__sales_document_english_name_snapshot.sql","__sales_alias_document_evidence.sql",
                    "__stock_document_item_line_warehouse_and_place_learning.sql"}){
                java.nio.file.Path bridge=migrationFiles.stream()
                        .filter(file->file.getFileName().toString().endsWith(suffix))
                        .findFirst().orElseThrow();
                db.execute(java.nio.file.Files.readString(bridge));
            }
        }catch(java.io.IOException failure){throw new java.io.UncheckedIOException(failure);}
        assertEquals(730,latestRecordedMigration(),"compatibility bridges must not advance Flyway history");
        assertFalse(db.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='production_material_discovery_requests'
                    AND column_name='request_no')
                """,Boolean.class),"the V731 number column must not exist while seeding historical requests");
        assertEquals(List.of("extra_columns","goods_name_en_snapshot"),db.queryForList("""
                SELECT column_name FROM information_schema.columns
                WHERE table_schema='public' AND table_name='sales_order_items'
                  AND column_name IN('extra_columns','goods_name_en_snapshot') ORDER BY column_name
                """,String.class));
    }
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void forwardBackfillAndConcurrentRequestsPreservePermanentIdentityAndNeverCreateEmptyDraws() throws Exception {
        var first=task();var second=task();var third=task();
        long firstVersion=first.version();String firstKey="old-pending-"+first.segment;
        UUID pending=legacyRequest(first,firstVersion,firstKey,false);
        UUID cancelled=legacyRequest(second,second.version(),"old-cancelled-"+second.segment,true);
        UUID configured=legacyRequest(third,third.version(),"old-configured-"+third.segment,false);
        legacyConfigure(third,configured);
        Map<UUID,String> before=new LinkedHashMap<>();
        for(UUID id:List.of(pending,cancelled,configured))before.put(id,db.queryForObject("SELECT to_jsonb(request)::text FROM production_material_discovery_requests request WHERE id=?",String.class,id));
        String materialFacts=materialFacts();
        String reserved="LQ"+db.queryForObject("SELECT to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai','YYYYMMDD')",String.class)+"000007";
        db.queryForObject("SELECT fn_claim_global_business_identifier(?,'PRODUCTION_MATERIAL_REQUEST',?,NULL,'production_material_discovery_requests')::text",String.class,reserved,UUID.randomUUID());

        var flyway=Flyway.configure().dataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword())
                .locations("classpath:db/migration").target("731").load();
        assertEquals(730,latestRecordedMigration());
        assertEquals(1,flyway.migrate().migrationsExecuted);
        assertEquals(731,latestRecordedMigration());
        flyway.validate();assertEquals(0,flyway.migrate().migrationsExecuted);
        assertEquals(materialFacts,materialFacts(),"number backfill must not alter demands, reservations, documents, lines or request authorizations");
        Set<String> numbers=new HashSet<>();
        for(UUID id:before.keySet()) {
            assertEquals(before.get(id),db.queryForObject("SELECT (to_jsonb(request)-'request_no')::text FROM production_material_discovery_requests request WHERE id=?",String.class,id));
            String number=db.queryForObject("SELECT request_no FROM production_material_discovery_requests WHERE id=?",String.class,id);
            assertTrue(number.matches("LQ[0-9]{14}"));assertTrue(Integer.parseInt(number.substring(10))>7);
            assertTrue(numbers.add(number));assertReservedFor(number,id);
        }
        first.fixture.loginAs(first.world.superAdminUserId());
        Detail replay=first.discovery.request(first.segment,new Request(firstVersion,firstKey));
        assertEquals(pending,replay.requestId());assertTrue(numbers.contains(replay.requestNo()));
        assertTrue(replay.drawDocIds().isEmpty());assertTrue(replay.drawDocuments().isEmpty());
        assertEquals(1,db.queryForObject("SELECT count(*) FROM stock_documents WHERE doc_type='DRAW'",Integer.class));
        assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("UPDATE production_material_discovery_requests SET request_no=? WHERE id=?","LQ20260927000099",pending));
        assertThrows(org.springframework.dao.DataAccessException.class,()->db.queryForObject("SELECT fn_claim_global_business_identifier(?,'STOCK_DRAW',?,NULL,'stock_documents')::text",String.class,replay.requestNo(),UUID.randomUUID()));
        RuntimeException history=assertThrows(RuntimeException.class,()->db.update("UPDATE production_material_discovery_lines SET qty=qty WHERE request_id=?",configured));
        assertTrue(history.toString().contains("Material discovery evidence is append-only"),history.toString());
        RuntimeException prefixConflict=assertThrows(RuntimeException.class,()->db.update("""
                INSERT INTO business_identifier_namespaces(namespace_key,identifier_family,fixed_prefix,source_table,identifier_column)
                VALUES('MATERIAL_REQUEST_PREFIX_PROBE','DOCUMENT','LQ','production_material_discovery_requests','idempotency_key')
                """));
        assertTrue(prefixConflict.toString().contains("prefix"),prefixConflict.toString());
        var transaction=new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class));
        RuntimeException exhausted=assertThrows(RuntimeException.class,()->transaction.execute(status->{
            db.update("UPDATE business_document_sequences SET last_seq=999999 WHERE namespace_key='PRODUCTION_MATERIAL_REQUEST' AND sequence_date=(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai')::date");
            return beans.getBean(com.uten.imp.common.docnumber.DocNumberService.class).nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.PRODUCTION_MATERIAL_REQUEST);
        }));
        assertTrue(causes(exhausted).contains("business_document_sequences_range_chk"),causes(exhausted));

        var repeated=task();long version=repeated.version();String key="concurrent-number-"+UUID.randomUUID();
        var command=new Request(version,key);
        var authentication=SecurityContextHolder.getContext().getAuthentication();
        CountDownLatch start=new CountDownLatch(1);
        try(var pool=Executors.newFixedThreadPool(2)) {
            var operation=(java.util.concurrent.Callable<Detail>)()->{SecurityContextHolder.getContext().setAuthentication(authentication);
                try{start.await();return repeated.discovery.request(repeated.segment,command);}finally{SecurityContextHolder.clearContext();}};
            var a=pool.submit(operation);var b=pool.submit(operation);start.countDown();
            Detail left=a.get(90,TimeUnit.SECONDS),right=b.get(90,TimeUnit.SECONDS);
            assertEquals(left,right);assertTrue(numbers.add(left.requestNo()));assertReservedFor(left.requestNo(),left.requestId());
        }
        var independentA=task();var independentB=task();
        var concurrentAuthentication=SecurityContextHolder.getContext().getAuthentication();
        CountDownLatch separateStart=new CountDownLatch(1);
        try(var pool=Executors.newFixedThreadPool(2)) {
            List<java.util.concurrent.Future<Detail>> results=new ArrayList<>();
            for(var task:List.of(independentA,independentB)) {
                long expected=task.version();String requestKey="independent-number-"+UUID.randomUUID();
                results.add(pool.submit(()->{SecurityContextHolder.getContext().setAuthentication(concurrentAuthentication);
                    try{separateStart.await();return task.discovery.request(task.segment,new Request(expected,requestKey));}
                    finally{SecurityContextHolder.clearContext();}}));
            }
            separateStart.countDown();
            for(var result:results){Detail detail=result.get(90,TimeUnit.SECONDS);assertTrue(numbers.add(detail.requestNo()));assertReservedFor(detail.requestNo(),detail.requestId());}
        }
        Detail original=repeated.discovery.detail(repeated.discovery.context(repeated.segment).requestId());
        var withdrawal=repeated.discovery.cancel(original.requestId(),new Request(original.version(),"withdraw-number-"+UUID.randomUUID()));
        assertEquals(original.requestNo(),withdrawal.requestNo());
        Detail next=repeated.discovery.request(repeated.segment,new Request(repeated.version(),"new-number-"+UUID.randomUUID()));
        assertTrue(numbers.add(next.requestNo()));assertReservedFor(original.requestNo(),original.requestId());assertReservedFor(next.requestNo(),next.requestId());
        String factsBeforeDuplicate=materialFacts();
        Long nextSequence=db.queryForObject("SELECT last_seq FROM business_document_sequences WHERE namespace_key='PRODUCTION_MATERIAL_REQUEST' AND sequence_date=(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai')::date",Long.class);
        ApiException duplicate=assertThrows(ApiException.class,()->repeated.discovery.request(repeated.segment,new Request(repeated.version(),"duplicate-number-"+UUID.randomUUID())));
        assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT,duplicate.getCode());assertTrue(duplicate.getMessage().contains("已提交领料"));
        assertEquals(next, repeated.discovery.detail(next.requestId()));
        assertEquals(nextSequence,db.queryForObject("SELECT last_seq FROM business_document_sequences WHERE namespace_key='PRODUCTION_MATERIAL_REQUEST' AND sequence_date=(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai')::date",Long.class));
        assertEquals(factsBeforeDuplicate,materialFacts());
        assertEquals(1,db.queryForObject("SELECT count(*) FROM stock_documents WHERE doc_type='DRAW'",Integer.class));
        assertEquals(numbers.size(),db.queryForObject("SELECT count(DISTINCT request_no) FROM production_material_discovery_requests",Integer.class));
    }

    private ProductionMaterialDiscoveryEndToEndTest task(){var fixture=new ProductionMaterialDiscoveryEndToEndTest();beans.autowireBean(fixture);fixture.prepare();return fixture;}
    private int latestRecordedMigration(){return db.queryForObject("SELECT MAX(version::integer) FROM flyway_schema_history WHERE success AND version IS NOT NULL",Integer.class);}
    private UUID legacyRequest(ProductionMaterialDiscoveryEndToEndTest task,long version,String key,boolean cancel){
        UUID id=UUID.randomUUID();
        db.update("""
                INSERT INTO production_material_discovery_requests(id,execution_segment_id,expected_version,created_by,idempotency_key,request_hash)
                VALUES(?,?,?,?,?,?)
                """,id,task.segment,version,task.world.superAdminUserId(),key,
                CanonicalFingerprint.sha256(List.of("DISCOVERY-REQUEST",task.segment.toString(),Long.toString(version))));
        db.update("UPDATE production_execution_segments SET lock_version=lock_version+1 WHERE id=?",task.segment);
        if(cancel) {
            db.update("""
                    UPDATE production_material_discovery_requests SET status='CANCELLED',row_version=row_version+1,
                      cancelled_by=?,cancelled_at=now(),cancellation_key=?,cancellation_hash=? WHERE id=?
                    """,task.world.superAdminUserId(),"old-withdraw-"+id,"0".repeat(64),id);
            db.update("UPDATE production_execution_segments SET lock_version=lock_version+1 WHERE id=?",task.segment);
        }
        return id;
    }
    private void assertReservedFor(String number,UUID request){
        assertEquals(request,db.queryForObject("SELECT entity_id FROM business_identifier_reservation_members WHERE normalized_identifier=? AND owner_domain='PRODUCTION_MATERIAL_REQUEST'",UUID.class,number));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM business_identifier_reservations WHERE normalized_identifier=?",Integer.class,number));
    }
    /** Reproduce a valid V730 warehouse configuration using its existing guarded
     * demand/reservation/DRAW operations. No trigger or quantity guard is disabled. */
    private void legacyConfigure(ProductionMaterialDiscoveryEndToEndTest task,UUID request){
        task.fixture.loginAs(task.world.superAdminUserId());task.receive(task.world.goodsD(),"2");
        new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class)).executeWithoutResult(status->{
            beans.getBean(com.uten.imp.security.TxSessionVars.class).bind();
            var footprint=beans.getBean(com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService.class).beginPlan(task.plan,
                    List.of(new com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService.RequestedLine(task.world.goodsD(),null,null)));
            Map<String,Object> context=db.queryForMap("SELECT package_id,source_plan_item_id,COALESCE(material_snapshot_product_qty,planned_qty) output,lock_version FROM production_execution_segments WHERE id=? FOR UPDATE",task.segment);
            footprint.verifyUnchanged();UUID demand=UUID.randomUUID();UUID actor=task.world.superAdminUserId();
            BigDecimal output=(BigDecimal)context.get("output");long version=((Number)context.get("lock_version")).longValue();
            String hash=CanonicalFingerprint.sha256(List.of("legacy-configuration",request.toString()));
            db.update("""
                    INSERT INTO production_material_demands(id,package_id,plan_id,warehouse_id,goods_id,color_id,unit_id,required_qty,
                      supply_route,idempotency_key,execution_segment_id,source_plan_item_id,per_product_qty,requirement_mode,
                      required_for_product_qty,requirement_fingerprint,created_by,updated_by)
                    VALUES(?,?,?,?,?,NULL,?,1,'BUY',?,?,?,?, 'EXACT_SNAPSHOT',?,?,?,?)
                    """,demand,context.get("package_id"),task.plan,task.world.warehouseId(),task.world.goodsD(),task.world.unitId(),
                    "DISCOVERY:"+request+":"+demand,task.segment,context.get("source_plan_item_id"),BigDecimal.ONE.divide(output,6,java.math.RoundingMode.UP),output,hash,actor,actor);
            db.update("INSERT INTO production_material_discovery_lines(request_id,demand_id,goods_id,unit_id,warehouse_id,qty,created_by) VALUES(?,?,?,?,?,1,?)",
                    request,demand,task.world.goodsD(),task.world.unitId(),task.world.warehouseId(),actor);
            db.update("UPDATE production_material_discovery_requests SET status='CONFIGURED',row_version=row_version+1,configured_by=?,configured_at=now(),configuration_key=?,configuration_hash=? WHERE id=?",
                    actor,"legacy-config-"+request,hash,request);
            db.update("""
                    UPDATE production_execution_segments SET material_requirement_mode='DEMANDED',zero_material_reason=NULL,
                      zero_material_analysis_id=NULL,zero_material_exception_reason=NULL,zero_material_authorized_by=NULL,
                      lock_version=lock_version+1,updated_at=now(),updated_by=? WHERE id=?
                    """,actor,task.segment);
            List<UUID> documents=beans.getBean(com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService.class).prepareDiscoveredMaterials(task.segment,request);
            String ids="{"+String.join(",",documents.stream().map(UUID::toString).toList())+"}";
            db.update("""
                    INSERT INTO production_execution_segment_events(execution_segment_id,action,idempotency_key,request_hash,
                      expected_version,resulting_version,created_by,draw_document_ids,draw_item_quantities)
                    VALUES(?,'DRAW_REQUEST',?,?,?,?,?,CAST(? AS uuid[]),
                      (SELECT jsonb_object_agg(item.id::text,item.qty) FROM stock_document_items item WHERE item.doc_id=ANY(CAST(? AS uuid[])) AND NOT item.is_deleted))
                    """,task.segment,"DISCOVERY:"+request,hash,version,version+1,actor,ids,ids);
        });
    }
    private String materialFacts(){return db.queryForObject("""
            SELECT jsonb_build_object(
              'demands',(SELECT jsonb_agg(to_jsonb(value) ORDER BY id) FROM production_material_demands value),
              'reservations',(SELECT jsonb_agg(to_jsonb(value) ORDER BY id) FROM stock_reservations value),
              'documents',(SELECT jsonb_agg(to_jsonb(value) ORDER BY id) FROM stock_documents value),
              'items',(SELECT jsonb_agg(to_jsonb(value) ORDER BY id) FROM stock_document_items value),
              'events',(SELECT jsonb_agg(to_jsonb(value) ORDER BY id) FROM production_execution_segment_events value))::text
            """,String.class);}
    private String causes(Throwable failure){StringBuilder result=new StringBuilder();for(Throwable value=failure;value!=null;value=value.getCause())result.append(value).append('\n');return result.toString();}
}
