package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts.*;
import com.uten.imp.support.MigratedSchemaBaseline;
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
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;

import java.math.BigDecimal;
import java.util.*;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/** Online retries/concurrency keep one permanent LQ number per material request in the
 * global registry, and numbering never creates a physical stock document. A private
 * current-schema database keeps the whole-database DRAW, sequence and number counts exact. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners=ProductionMaterialRequestNumberPostgresTest.Cleanup.class,
        mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
    "spring.profiles.active=dev",
    "uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
    "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
    "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
    "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
    "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
    "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
    "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionMaterialRequestNumberPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) throws Exception {
        database=MigratedSchemaBaseline.openDatabase("material_request_numbers");
        registry.add("spring.datasource.url",database::getJdbcUrl);
        registry.add("spring.datasource.username",database::getUsername);
        registry.add("spring.datasource.password",database::getPassword);
        // Uploads stay enabled for the real services; keep any attachment I/O out of the shared server/data tree.
        java.nio.file.Path attachments=java.nio.file.Files.createTempDirectory("material-request-number-");
        registry.add("uten.storage.local-dir",attachments::toString);
    }
    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
        @Override public void afterTestClass(TestContext ignored) throws Exception {if(database!=null)database.close();}
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void onlineRetriesAndConcurrencyKeepOnePermanentNumberAndNeverCreateEmptyDraws() throws Exception {
        Set<String> numbers=new HashSet<>();
        var first=task();
        Detail pending=first.discovery.request(first.segment,new Request(first.version(),"number-pending-"+first.segment));
        assertNewNumber(numbers,pending);assertTrue(pending.drawDocIds().isEmpty());assertTrue(pending.drawDocuments().isEmpty());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_documents WHERE doc_type='DRAW'",Integer.class));
        RuntimeException renumbered=assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("UPDATE production_material_discovery_requests SET request_no=? WHERE id=?","LQ20260927000099",pending.requestId()));
        assertTrue(renumbered.toString().contains("immutable"),renumbered.toString());
        assertThrows(org.springframework.dao.DataAccessException.class,()->db.queryForObject("SELECT fn_claim_global_business_identifier(?,'STOCK_DRAW',?,NULL,'stock_documents')::text",String.class,pending.requestNo(),UUID.randomUUID()));
        // The warehouse configures this request: its real DRAW is the only physical document this class creates.
        first.receive(first.world.goodsD(),"2");
        Detail configured=first.discovery.configure(pending.requestId(),new Configure(pending.version(),"number-configure-"+first.segment,
                List.of(new Material(first.world.goodsD(),null,first.world.unitId(),first.world.warehouseId(),BigDecimal.ONE))));
        assertEquals(pending.requestNo(),configured.requestNo());assertEquals(1,configured.drawDocIds().size());
        RuntimeException history=assertThrows(RuntimeException.class,()->db.update("UPDATE production_material_discovery_lines SET qty=qty WHERE request_id=?",configured.requestId()));
        assertTrue(history.toString().contains("Material discovery evidence is append-only"),history.toString());
        RuntimeException prefixConflict=assertThrows(RuntimeException.class,()->db.update("""
                INSERT INTO business_identifier_namespaces(namespace_key,identifier_family,fixed_prefix,source_table,identifier_column)
                VALUES('MATERIAL_REQUEST_PREFIX_PROBE','DOCUMENT','LQ','production_material_discovery_requests','idempotency_key')
                """));
        assertTrue(prefixConflict.toString().contains("prefix"),prefixConflict.toString());
        var transaction=new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class));
        String sequencesBeforeExhaustion=requestSequences();
        RuntimeException exhausted=assertThrows(RuntimeException.class,()->transaction.execute(status->{
            // Same transaction timestamp as DocNumberService, so the exhausted day is the day it allocates.
            db.update("""
                    INSERT INTO business_document_sequences(namespace_key,sequence_date,last_seq)
                    VALUES('PRODUCTION_MATERIAL_REQUEST',(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai')::date,999999)
                    ON CONFLICT(namespace_key,sequence_date) DO UPDATE SET last_seq=999999
                    """);
            return beans.getBean(com.uten.imp.common.docnumber.DocNumberService.class).nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.PRODUCTION_MATERIAL_REQUEST);
        }));
        assertTrue(causes(exhausted).contains("business_document_sequences_range_chk"),causes(exhausted));
        assertEquals(sequencesBeforeExhaustion,requestSequences(),"an exhausted day rolls back without consuming a number");

        var repeated=task();long version=repeated.version();String key="concurrent-number-"+UUID.randomUUID();
        var command=new Request(version,key);
        var authentication=SecurityContextHolder.getContext().getAuthentication();
        CountDownLatch start=new CountDownLatch(1);
        try(var pool=Executors.newFixedThreadPool(2)) {
            var operation=(java.util.concurrent.Callable<Detail>)()->{SecurityContextHolder.getContext().setAuthentication(authentication);
                try{start.await();return repeated.discovery.request(repeated.segment,command);}finally{SecurityContextHolder.clearContext();}};
            var a=pool.submit(operation);var b=pool.submit(operation);start.countDown();
            Detail left=a.get(90,TimeUnit.SECONDS),right=b.get(90,TimeUnit.SECONDS);
            assertEquals(left,right);assertNewNumber(numbers,left);
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
            for(var result:results)assertNewNumber(numbers,result.get(90,TimeUnit.SECONDS));
        }
        Detail original=repeated.discovery.detail(repeated.discovery.context(repeated.segment).requestId());
        var withdrawal=repeated.discovery.cancel(original.requestId(),new Request(original.version(),"withdraw-number-"+UUID.randomUUID()));
        assertEquals(original.requestNo(),withdrawal.requestNo());
        Detail next=repeated.discovery.request(repeated.segment,new Request(repeated.version(),"new-number-"+UUID.randomUUID()));
        assertNewNumber(numbers,next);assertReservedFor(original.requestNo(),original.requestId());
        String factsBeforeDuplicate=materialFacts();
        String sequencesBeforeDuplicate=requestSequences();
        ApiException duplicate=assertThrows(ApiException.class,()->repeated.discovery.request(repeated.segment,new Request(repeated.version(),"duplicate-number-"+UUID.randomUUID())));
        assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT,duplicate.getCode());assertTrue(duplicate.getMessage().contains("已提交领料"));
        assertEquals(next, repeated.discovery.detail(next.requestId()));
        assertEquals(sequencesBeforeDuplicate,requestSequences());
        assertEquals(factsBeforeDuplicate,materialFacts());
        assertEquals(1,db.queryForObject("SELECT count(*) FROM stock_documents WHERE doc_type='DRAW'",Integer.class));
        assertEquals(numbers.size(),db.queryForObject("SELECT count(DISTINCT request_no) FROM production_material_discovery_requests",Integer.class));
    }

    private ProductionMaterialDiscoveryEndToEndTest task(){var fixture=new ProductionMaterialDiscoveryEndToEndTest();beans.autowireBean(fixture);fixture.prepare();return fixture;}
    private void assertNewNumber(Set<String> numbers,Detail request){
        assertTrue(request.requestNo().matches("LQ[0-9]{14}"),request.requestNo());
        assertTrue(numbers.add(request.requestNo()),request.requestNo());assertReservedFor(request.requestNo(),request.requestId());
    }
    private void assertReservedFor(String number,UUID request){
        assertEquals(request,db.queryForObject("SELECT entity_id FROM business_identifier_reservation_members WHERE normalized_identifier=? AND owner_domain='PRODUCTION_MATERIAL_REQUEST'",UUID.class,number));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM business_identifier_reservations WHERE normalized_identifier=?",Integer.class,number));
    }
    /** Every day of the LQ namespace, so the check does not depend on which calendar day it runs. */
    private String requestSequences(){return db.queryForObject("""
            SELECT COALESCE(jsonb_agg(jsonb_build_array(sequence_date,last_seq) ORDER BY sequence_date),'[]'::jsonb)::text
            FROM business_document_sequences WHERE namespace_key='PRODUCTION_MATERIAL_REQUEST'
            """,String.class);}
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
