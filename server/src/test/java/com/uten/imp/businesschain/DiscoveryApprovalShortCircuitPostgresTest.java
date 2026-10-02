package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.fulfillment.ProductionDrawDiscoveryBatchContracts;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts;
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
import java.util.List;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Real fifty-document source and replay regression with a strict production-proof read budget. */
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
class DiscoveryApprovalShortCircuitPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry p){FullChainEndToEndTest.registerDataSource(p);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    static final String PATH="/api/stock/docs/issue-discovery-batch";
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void productionDrawStillRejectsStandaloneApprovalWithoutStockOrSourceMutation() {
        var c=prepare(1,true);
        var configured=c.task().discovery.configure(c.pending().requestId(),
                new ProductionMaterialDiscoveryContracts.Configure(c.pending().version(),"standalone-"+UUID.randomUUID(),
                        List.of(new ProductionMaterialDiscoveryContracts.Material(c.task().world.goodsD(),null,
                                c.task().world.unitId(),c.warehouses().getFirst(),BigDecimal.ONE))));
        assertEquals(1,configured.drawDocIds().size());
        UUID doc=configured.drawDocIds().getFirst();
        var before=db.queryForMap("SELECT status,issue_status FROM stock_documents WHERE id=?",doc);
        ApiException rejected=assertThrows(ApiException.class,()->c.task().stock.approve(doc));
        assertTrue(rejected.getMessage().contains("生产领料单不能单独审核"));
        assertEquals(before,db.queryForMap("SELECT status,issue_status FROM stock_documents WHERE id=?",doc));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",Integer.class,doc));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_material_stock_events WHERE stock_document_id=?",Integer.class,doc));
        assertEquals(0,db.queryForObject("""
                SELECT count(*) FROM production_material_stock_postings posting
                JOIN stock_document_items item ON item.id=posting.stock_document_item_id WHERE item.doc_id=?
                """,Integer.class,doc));
        assertEquals(0,BigDecimal.ONE.compareTo(db.queryForObject(
                "SELECT sum(qty) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,
                c.warehouses().getFirst(),c.task().world.goodsD())));
    }

    @Test void fiftyDiscoveryDocumentsKeepEverySourceAndReplayWithoutTheImpossibleApprovalGuardRead() throws Exception {
        var c=prepare(50,true);Authentication actor=SecurityContextHolder.getContext().getAuthentication();
        String priorTrace=System.getProperty("uten.jdbc.measurement.trace-directory");
        java.nio.file.Path trace=java.nio.file.Path.of(".local-tmp/discovery-approval-short-circuit-trace").toAbsolutePath();
        System.setProperty("uten.jdbc.measurement.trace-directory",trace.toString());
        var sample=ProductionJdbcMeasurement.begin();long started=System.nanoTime();
        JsonNode result;
        try { result=issue(c.request(),actor,200); }
        finally {
            try { ProductionJdbcMeasurement.end(); }
            finally {
                if(priorTrace==null)System.clearProperty("uten.jdbc.measurement.trace-directory");
                else System.setProperty("uten.jdbc.measurement.trace-directory",priorTrace);
            }
        }
        long commandMillis=(System.nanoTime()-started)/1_000_000L;
        assertEquals(50,result.path("issuedCount").asInt());
        List<UUID> documents=db.queryForList("SELECT unnest(document_ids) FROM production_draw_issue_batches WHERE idempotency_key=?",UUID.class,c.request().idempotencyKey());
        assertEquals(50,documents.size());assertEquals(50,documents.stream().distinct().count());
        assertEquals(50,db.queryForObject("SELECT count(*) FROM production_material_discovery_lines WHERE request_id=?",Integer.class,c.pending().requestId()));
        var named=new NamedParameterJdbcTemplate(db);var ids=java.util.Map.of("ids",documents);
        Set<UUID> expectedWarehouses=new HashSet<>(c.warehouses());
        assertEquals(50,expectedWarehouses.size());
        assertEquals(expectedWarehouses,new HashSet<>(named.queryForList(
                "SELECT warehouse_id FROM stock_documents WHERE id IN(:ids)",ids,UUID.class)));
        assertEquals(50,named.queryForObject(
                "SELECT count(*) FROM stock_document_items WHERE doc_id IN(:ids) AND NOT is_deleted",ids,Integer.class));
        assertEquals(50,db.queryForObject("""
                SELECT count(*) FROM production_material_discovery_lines line
                JOIN production_planning_package_document_items mapping
                  ON mapping.demand_id=line.demand_id AND mapping.document_type='DRAW'
                JOIN production_material_demands demand ON demand.id=mapping.demand_id
                JOIN production_planning_package_documents header ON header.package_id=mapping.package_id
                  AND header.document_type=mapping.document_type AND header.document_id=mapping.document_id
                  AND header.execution_segment_id=demand.execution_segment_id
                JOIN stock_document_items item ON item.id=mapping.document_item_id
                  AND item.doc_id=mapping.document_id AND NOT item.is_deleted
                JOIN stock_documents doc ON doc.id=item.doc_id
                  AND doc.warehouse_id=line.warehouse_id AND NOT doc.is_deleted
                WHERE line.request_id=? AND demand.execution_segment_id=? AND item.execution_segment_id IS NULL
                  AND item.goods_id=line.goods_id AND item.color_id IS NOT DISTINCT FROM line.color_id
                  AND item.unit_id=line.unit_id AND item.qty=1 AND item.issued_qty=1 AND line.qty=1
                """,Integer.class,c.pending().requestId(),c.task().segment));
        assertEquals(50,named.queryForObject("""
                SELECT count(*) FROM stock_movements movement
                JOIN stock_document_items item ON item.id=movement.source_item_id AND item.doc_id=movement.source_doc_id
                JOIN stock_documents doc ON doc.id=item.doc_id
                WHERE item.doc_id IN(:ids) AND movement.movement_type=5 AND movement.direction=-1
                  AND movement.qty=1 AND movement.goods_id=item.goods_id
                  AND movement.color_id IS NOT DISTINCT FROM item.color_id AND movement.warehouse_id=doc.warehouse_id
                """,ids,Integer.class));
        assertEquals(50,named.queryForObject("""
                SELECT count(*) FROM (
                  SELECT item.id FROM stock_document_items item
                  JOIN production_material_stock_postings posting ON posting.stock_document_item_id=item.id
                  WHERE item.doc_id IN(:ids) AND posting.posting_type='ISSUE'
                  GROUP BY item.id HAVING count(*)=1 AND sum(posting.qty_base)=1
                ) exact_postings
                """,ids,Integer.class));
        assertEquals(0,named.queryForObject("""
                SELECT count(*) FROM stock_document_items WHERE doc_id IN(:ids) AND NOT is_deleted
                  AND fn_production_draw_item_requested_qty(id)<>issued_qty
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
        Set<UUID> receiptIds=new HashSet<>();
        receipt.path("docIds").forEach(id->receiptIds.add(UUID.fromString(id.asText())));
        assertEquals(new HashSet<>(documents),receiptIds);
        assertEquals(result,receipt.path("result"));
        var movementsBefore=named.queryForList(
                "SELECT * FROM stock_movements WHERE source_doc_id IN(:ids) ORDER BY id",ids);
        var postingsBefore=named.queryForList("""
                SELECT posting.* FROM production_material_stock_postings posting
                JOIN stock_document_items item ON item.id=posting.stock_document_item_id
                WHERE item.doc_id IN(:ids) ORDER BY posting.id
                """,ids);
        JsonNode replay=issue(c.request(),actor,200);
        assertEquals(0,replay.path("issuedCount").asInt());assertEquals(50,replay.path("replayedCount").asInt());
        assertEquals(50,named.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id IN(:ids)",ids,Integer.class));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_draw_issue_batches WHERE idempotency_key=?",Integer.class,c.request().idempotencyKey()));
        assertEquals(movementsBefore,named.queryForList(
                "SELECT * FROM stock_movements WHERE source_doc_id IN(:ids) ORDER BY id",ids));
        assertEquals(postingsBefore,named.queryForList("""
                SELECT posting.* FROM production_material_stock_postings posting
                JOIN stock_document_items item ON item.id=posting.stock_document_item_id
                WHERE item.doc_id IN(:ids) ORDER BY posting.id
                """,ids));
        assertEquals(receipt,readReceipt(c.request().idempotencyKey(),actor));
        System.out.println("CLOSEOUT-DISCOVERY-SHORT-CIRCUIT hostHttpMillis="+commandMillis
                +" issueMetrics="+json.writeValueAsString(sample.result())+" preparationExcluded=true nestedFootprint=false originsTrace=true NOT_PERFORMANCE_GATE");
        assertEquals(200L,sample.fingerprints.getOrDefault("54edbba059ec202a",0L).longValue(),
                "workshop-request gates are preserved");
        assertEquals(201L,sample.fingerprints.getOrDefault("7d540ab7b6b7bc21",0L).longValue(),
                "canonical inventory locks and savepoint-safe reacquisition are preserved");
        // Assert the budget last: the old-source red run must first prove the same
        // successful source, quantity, lock and replay invariants as the green run.
        assertEquals(250L,sample.fingerprints.getOrDefault("3c6c71da594b4d3e",0L).longValue(),
                "approval permission short-circuits only the impossible rejection read");
    }

    private Case prepare(int count,boolean receive) {
        var task=new ProductionMaterialDiscoveryEndToEndTest();beans.autowireBean(task);task.prepare();
        var pending=task.discovery.request(task.segment,new ProductionMaterialDiscoveryContracts.Request(task.version(),
                "known-fifty-"+UUID.randomUUID(),List.of(new ProductionMaterialDiscoveryContracts.RequestedMaterial(
                task.world.goodsD(),null,task.world.unitId(),null))));
        var materials=new ArrayList<ProductionMaterialDiscoveryContracts.Material>();
        var warehouses=new ArrayList<UUID>();
        for(int i=0;i<count;i++) {
            UUID warehouse=UUID.randomUUID();
            warehouses.add(warehouse);
            db.update("INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",
                    warehouse,"DISCOVERY-FIFTY-"+warehouse,"实际物料叶仓",task.world.warehouseId());
            if(receive)task.receive(task.world.goodsD(),"1",warehouse);
            materials.add(new ProductionMaterialDiscoveryContracts.Material(task.world.goodsD(),null,task.world.unitId(),warehouse,BigDecimal.ONE));
        }
        var request=new ProductionDrawDiscoveryBatchContracts.Request("discovery-limit-"+UUID.randomUUID(),List.of(),
                List.of(new ProductionDrawDiscoveryBatchContracts.Discovery(pending.requestId(),pending.version(),materials)),null);
        return new Case(task,pending,request,List.copyOf(warehouses));
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
                        ProductionDrawDiscoveryBatchContracts.Request request,List<UUID> warehouses){}
}
