package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.production.fulfillment.ProductionDrawDiscoveryBatchContracts;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts;
import com.uten.imp.features.production.fulfillment.ProductionDrawDiscoveryBatchService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Real material discovery split by actual warehouses: fifty succeeds atomically, fifty-one rolls back. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000","uten.workshop-material.auto-close.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.concurrency.verify-nested-footprint=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
@Import(ProductionJdbcMeasurement.Configuration.class)
class DiscoveryFiftyBoundaryPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry p){FullChainEndToEndTest.registerDataSource(p);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @Autowired ProductionDrawDiscoveryBatchService batches;
    static final String PATH="/api/stock/docs/issue-discovery-batch";
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void oneKnownMaterialRequestExpandsToFiftyActualWarehousesAndCommitsEveryOriginalMovementOnce() throws Exception {
        var c=prepare(50,true);Authentication actor=SecurityContextHolder.getContext().getAuthentication();
        var sample=ProductionJdbcMeasurement.begin();long started=System.nanoTime();
        JsonNode result;
        try { result=issue(c.request(),actor,200); }
        finally { ProductionJdbcMeasurement.end(); }
        long commandMillis=(System.nanoTime()-started)/1_000_000L;
        assertEquals(50,result.path("issuedCount").asInt());
        List<UUID> documents=db.queryForList("SELECT unnest(document_ids) FROM production_draw_issue_batches WHERE idempotency_key=?",UUID.class,c.request().idempotencyKey());
        assertEquals(50,documents.size());assertEquals(50,documents.stream().distinct().count());
        assertEquals(50,db.queryForObject("SELECT count(*) FROM production_material_discovery_lines WHERE request_id=?",Integer.class,c.pending().requestId()));
        var named=new NamedParameterJdbcTemplate(db);var ids=java.util.Map.of("ids",documents);
        assertEquals(0,named.queryForObject("""
                SELECT count(*) FROM stock_document_items WHERE doc_id IN(:ids) AND NOT is_deleted
                  AND fn_production_draw_item_requested_qty(id)>issued_qty
                """,ids,Integer.class));
        assertEquals(50,named.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id IN(:ids) AND movement_type=5 AND direction=-1",ids,Integer.class));
        assertEquals(0,new BigDecimal("50").compareTo(named.queryForObject(
                "SELECT sum(qty) FROM stock_movements WHERE source_doc_id IN(:ids) AND movement_type=5 AND direction=-1",ids,BigDecimal.class)));
        assertEquals(0,new BigDecimal("50").compareTo(db.queryForObject("""
                SELECT sum(posting.qty_base) FROM production_material_stock_postings posting
                JOIN production_material_demands demand ON demand.id=posting.demand_id
                WHERE demand.execution_segment_id=? AND posting.posting_type='ISSUE'
                """,BigDecimal.class,c.task().segment)));
        assertEquals(0,db.queryForObject("""
                SELECT count(*) FROM stock_balances balance JOIN warehouses warehouse ON warehouse.id=balance.warehouse_id
                WHERE warehouse.parent_id=? AND balance.goods_id=? AND balance.qty<>0
                """,Integer.class,c.task().world.warehouseId(),c.task().world.goodsD()));
        JsonNode receipt=readReceipt(c.request().idempotencyKey(),actor);
        assertEquals("COMMITTED",receipt.path("state").asText());
        assertEquals(50,receipt.path("docIds").size());
        JsonNode replay=issue(c.request(),actor,200);
        assertEquals(0,replay.path("issuedCount").asInt());assertEquals(50,replay.path("replayedCount").asInt());
        assertEquals(50,named.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id IN(:ids)",ids,Integer.class));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_draw_issue_batches WHERE idempotency_key=?",Integer.class,c.request().idempotencyKey()));
        System.out.println("CLOSEOUT-DISCOVERY-FIFTY hostHttpMillis="+commandMillis
                +" issueMetrics="+json.writeValueAsString(sample.result())+" preparationExcluded=true nestedFootprint=false");
    }

    @Test void oneInputThatWouldExpandIntoFiftyOneDocumentsRollsBackAllConfigurationsAndKeepsThePendingVersion() throws Exception {
        var c=prepare(51,true);Authentication actor=SecurityContextHolder.getContext().getAuthentication();
        long version=c.task().version();String xmin=db.queryForObject("SELECT xmin::text FROM production_material_discovery_requests WHERE id=?",String.class,c.pending().requestId());
        JsonNode failed=issue(c.request(),actor,422);
        assertTrue(failed.path("message").asText().contains("50"));
        assertEquals(xmin,db.queryForObject("SELECT xmin::text FROM production_material_discovery_requests WHERE id=?",String.class,c.pending().requestId()));
        assertEquals("PENDING",db.queryForObject("SELECT status FROM production_material_discovery_requests WHERE id=?",String.class,c.pending().requestId()));
        assertEquals(version,c.task().version());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_discovery_lines WHERE request_id=?",Integer.class,c.pending().requestId()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",Integer.class,c.task().segment));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_draw_issue_batches WHERE idempotency_key=?",Integer.class,c.request().idempotencyKey()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM plan_draw_links WHERE plan_id=?",Integer.class,c.task().plan));
        assertEquals("UNKNOWN",readReceipt(c.request().idempotencyKey(),actor).path("state").asText());
    }

    @Test void rawFiftyOneChoicesAreRejectedBeforeDeduplicationOrAnyDocumentLookup() throws Exception {
        var c=prepare(1,false);Authentication actor=SecurityContextHolder.getContext().getAuthentication();
        var raw=new ProductionDrawDiscoveryBatchContracts.Request("too-many-raw-"+UUID.randomUUID(),
                Collections.nCopies(51,UUID.randomUUID()),List.of(),null);
        JsonNode result=issue(raw,actor,422);assertTrue(result.path("message").asText().contains("50"));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_draw_issue_batches WHERE idempotency_key=?",Integer.class,raw.idempotencyKey()));
        assertEquals("PENDING",db.queryForObject("SELECT status FROM production_material_discovery_requests WHERE id=?",String.class,c.pending().requestId()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",Integer.class,c.task().segment));
    }

    private Case prepare(int count,boolean receive) {
        var task=new ProductionMaterialDiscoveryEndToEndTest();beans.autowireBean(task);task.prepare();
        var pending=task.discovery.request(task.segment,new ProductionMaterialDiscoveryContracts.Request(task.version(),
                "known-fifty-"+UUID.randomUUID(),List.of(new ProductionMaterialDiscoveryContracts.RequestedMaterial(
                task.world.goodsD(),null,task.world.unitId(),null))));
        var materials=new ArrayList<ProductionMaterialDiscoveryContracts.Material>();
        for(int i=0;i<count;i++) {
            UUID warehouse=UUID.randomUUID();
            db.update("INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",
                    warehouse,"DISCOVERY-FIFTY-"+warehouse,"实际物料叶仓",task.world.warehouseId());
            if(receive)task.receive(task.world.goodsD(),"1",warehouse);
            materials.add(new ProductionMaterialDiscoveryContracts.Material(task.world.goodsD(),null,task.world.unitId(),warehouse,BigDecimal.ONE));
        }
        var request=new ProductionDrawDiscoveryBatchContracts.Request("discovery-limit-"+UUID.randomUUID(),List.of(),
                List.of(new ProductionDrawDiscoveryBatchContracts.Discovery(pending.requestId(),pending.version(),materials)),null);
        return new Case(task,pending,request);
    }
    private JsonNode issue(ProductionDrawDiscoveryBatchContracts.Request request,Authentication actor,int expected) throws Exception {
        var response=http.perform(post(PATH).with(authentication(actor)).contentType("application/json")
                .content(json.writeValueAsBytes(request))).andReturn().getResponse();
        assertEquals(expected,response.getStatus(),response.getContentAsString());
        return json.readTree(response.getContentAsByteArray());
    }
    private JsonNode readReceipt(String key,Authentication actor) throws Exception {
        var response=http.perform(get(PATH+"/receipt").param("idempotencyKey",key).with(authentication(actor))).andReturn().getResponse();
        assertEquals(200,response.getStatus(),response.getContentAsString());
        return json.readTree(response.getContentAsByteArray());
    }
    private record Case(ProductionMaterialDiscoveryEndToEndTest task,ProductionMaterialDiscoveryContracts.Detail pending,
                        ProductionDrawDiscoveryBatchContracts.Request request){}
}
