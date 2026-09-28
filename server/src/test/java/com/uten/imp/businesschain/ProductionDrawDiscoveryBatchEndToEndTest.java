package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.features.production.fulfillment.ProductionDrawDiscoveryBatchContracts;
import com.uten.imp.features.production.fulfillment.ProductionDrawDiscoveryBatchService;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts;
import com.uten.imp.features.stock.dto.StockDocIssueBatchResponse;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.*;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static com.uten.imp.features.production.fulfillment.ProductionDrawDiscoveryBatchContracts.*;
import static com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts.Material;
import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.concurrency.verify-nested-footprint=true",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionDrawDiscoveryBatchEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionDrawDiscoveryBatchService batches;
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void mixedBatchConfirmsSplitWarehousesAndOrdinaryDrawOnceAndNeverReissuesAfterCancellation(){
        var first=task();var pendingFirst=suggest(first);UUID leafA=leaf(first),leafB=leaf(first);
        first.receive(first.world.goodsD(),"5",leafA);first.receive(first.world.goodsD(),"5",leafB);
        var second=task();var pendingSecond=suggest(second);second.receive(second.world.goodsD(),"6");
        var normal=task();normal.receive(normal.world.goodsD(),"6");
        // The legacy B task needs both C*3 and D*5; receiving only D leaves its
        // legitimate material gate closed even when the batch issues correctly.
        normal.receive(normal.world.goodsC(),"3");
        UUID normalDraw=legacyDraw(normal);
        // A legacy normal DRAW's plan may have no material-analysis link. Its whole
        // plan/BOM footprint must still join the initial batch lock prefix.
        assertNull(db.queryForObject("SELECT material_analysis_id FROM production_plans WHERE id=?",UUID.class,normal.plan));
        String key="mixed-known-"+UUID.randomUUID();
        var command=new Request(key,List.of(normalDraw),List.of(
                new Discovery(pendingFirst.requestId(),pendingFirst.version(),List.of(material(first,leafA,"2"),material(first,leafB,"3"))),
                new Discovery(pendingSecond.requestId(),pendingSecond.version(),List.of(material(second,second.world.warehouseId(),"2")))),"批量补齐后出库");
        var result=batches.issue(command);assertEquals(4,result.issuedCount());assertFalse(result.replayed());
        assertTrue(first.ready(),"the split-warehouse discovery task received its full requested material");
        assertTrue(second.ready(),"the second discovery task received its full requested material");
        assertTrue(normal.ready(),"the ordinary legacy B task received both C*3 and D*5");
        assertEquals(1,count("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",first.segment));
        assertEquals(2,first.discovery.detail(pendingFirst.requestId()).drawDocIds().size());
        assertEquals(0,count("SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted",first.world.goodsC()));
        var replay=batches.issue(new Request(key,List.of(normalDraw),List.of(command.discoveries().getLast(),
                new Discovery(pendingFirst.requestId(),pendingFirst.version(),List.of(material(first,leafB,"3.0000"),material(first,leafA,"2.0")))),command.reason()));
        assertTrue(replay.replayed());assertEquals(0,replay.issuedCount());assertEquals(4,replay.replayedCount());
        assertThrows(ApiException.class,()->batches.issue(new Request(key,List.of(),command.discoveries(),command.reason())));
        assertThrows(ApiException.class,()->batches.issue(new Request(key,command.docIds(),command.discoveries(),"另一备注")));
        assertThrows(ApiException.class,()->batches.issue(new Request("new-key-"+UUID.randomUUID(),command.docIds(),command.discoveries(),command.reason())));
        var reverse=new StockDocIssueRequest();reverse.setIdempotencyKey("batch-reverse-"+normalDraw);reverse.setReason("核对后取消本次发料");
        reverse.setLines(db.query("SELECT id,issued_qty FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",(rs,index)->{
            var line=new StockDocIssueRequest.Line();line.setItemId(rs.getObject(1,UUID.class));line.setQty(rs.getBigDecimal(2));return line;},normalDraw));
        normal.stock.reverseIssue(normalDraw,reverse);
        assertTrue(batches.issue(command).replayed());
        assertEquals(0,db.queryForObject("SELECT SUM(issued_qty) FROM stock_document_items WHERE doc_id=?",BigDecimal.class,normalDraw).signum());
        assertEquals(1,count("SELECT count(*) FROM production_draw_issue_batches WHERE idempotency_key=?",key));
        assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("UPDATE production_draw_issue_batches SET response_snapshot='{}'::jsonb WHERE idempotency_key=?",key));
        var actor=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        var limited=new AuthUser(actor.getId(),actor.getEmployeeId(),actor.getUsername(),Set.of("stock_doc:view","stock_doc:issue"),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(limited,null,limited.getAuthorities()));
        assertThrows(ApiException.class,()->batches.issue(command),"exact replay must still require approval authority");
    }

    @Test void aLaterInsufficientMaterialRollsBackEveryConfigurationAndTheSameKeyCanBeCorrected(){
        var first=task();var a=suggest(first);first.receive(first.world.goodsD(),"10");
        var second=task();var b=suggest(second);second.receive(second.world.goodsD(),"1");
        String key="all-or-nothing-"+UUID.randomUUID();
        var original=new Request(key,List.of(),List.of(new Discovery(a.requestId(),a.version(),List.of(material(first,first.world.warehouseId(),"2"))),
                new Discovery(b.requestId(),b.version(),List.of(material(second,second.world.warehouseId(),"20")))),null);
        assertThrows(ApiException.class,()->batches.issue(original));
        for(var entry:List.of(Map.entry(first,a),Map.entry(second,b))) {
            assertEquals("PENDING",entry.getKey().discovery.detail(entry.getValue().requestId()).status());
            assertEquals(0,count("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",entry.getKey().segment));
        }
        assertEquals(0,count("SELECT count(*) FROM production_draw_issue_batches WHERE idempotency_key=?",key));
        var corrected=new Request(key,List.of(),List.of(original.discoveries().getFirst(),
                new Discovery(b.requestId(),b.version(),List.of(material(second,second.world.warehouseId(),"1")))),null);
        assertEquals(2,batches.issue(corrected).issuedCount());
    }

    @Test void failureIssuingAnExistingDrawRollsBackNewMaterialConfiguration(){
        var first=task();var pending=suggest(first);first.receive(first.world.goodsD(),"2");
        var normal=task();var normalPending=suggest(normal);normal.receive(normal.world.goodsD(),"2");
        var defined=normal.discovery.configure(normalPending.requestId(),new ProductionMaterialDiscoveryContracts.Configure(
                normalPending.version(),"stopped-config-"+normal.segment,List.of(material(normal,normal.world.warehouseId(),"1"))));
        db.update("UPDATE production_plans SET is_stopped=TRUE WHERE id=?",normal.plan);
        String key="late-failure-"+UUID.randomUUID();
        assertThrows(ApiException.class,()->batches.issue(new Request(key,defined.drawDocIds(),List.of(
                new Discovery(pending.requestId(),pending.version(),List.of(material(first,first.world.warehouseId(),"1")))),null)));
        assertEquals("PENDING",first.discovery.detail(pending.requestId()).status());
        assertEquals(0,count("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",first.segment));
        assertEquals(0,count("SELECT count(*) FROM production_draw_issue_batches WHERE idempotency_key=?",key));
        assertEquals(0,db.queryForObject("SELECT SUM(issued_qty) FROM stock_document_items WHERE doc_id=?",BigDecimal.class,defined.drawDocIds().getFirst()).signum());
    }

    @Test void aLegacyCallerCannotPreoccupyTheMixedBatchChildIssueKey(){
        var discovered=task();var pending=suggest(discovered);discovered.receive(discovered.world.goodsD(),"3");
        var normal=task();var ordinaryPending=suggest(normal);normal.receive(normal.world.goodsD(),"3");
        var ordinary=normal.discovery.configure(ordinaryPending.requestId(),new ProductionMaterialDiscoveryContracts.Configure(
                ordinaryPending.version(),"preoccupy-config-"+normal.segment,List.of(material(normal,normal.world.warehouseId(),"2"))));
        UUID document=ordinary.drawDocIds().getFirst();
        var actor=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        String key="preoccupied-internal-"+UUID.randomUUID();
        // Before the fix, the public legacy endpoint could claim this predictable
        // internal batch key, then reverse it before the mixed command existed.
        var preoccupied=new StockDocIssueBatchRequest();
        preoccupied.setIdempotencyKey("DISCOVERY-BATCH:"+CanonicalFingerprint.sha256(List.of(actor.getId().toString(),key)));
        preoccupied.setDocIds(List.of(document));assertEquals(1,normal.stock.issueFullBatch(preoccupied).issuedCount());
        reverse(normal,document,"preoccupied-reverse-");
        assertEquals(0,issued(document).signum());
        var request=new Request(key,List.of(document),List.of(new Discovery(pending.requestId(),pending.version(),
                List.of(material(discovered,discovered.world.warehouseId(),"1")))),null);
        assertEquals(2,batches.issue(request).issuedCount());
        assertEquals(0,new BigDecimal("2").compareTo(issued(document)));
        UUID discoveredDocument=discovered.discovery.detail(pending.requestId()).drawDocIds().getFirst();
        assertEquals(0,BigDecimal.ONE.compareTo(issued(discoveredDocument)));
        assertEquals(1,count("SELECT count(*) FROM production_draw_issue_batches WHERE idempotency_key=?",key));
        reverse(normal,document,"post-batch-reverse-");
        assertTrue(batches.issue(request).replayed());
        assertEquals(0,issued(document).signum(),"the outer batch replay must never reissue cancelled inventory");
        assertEquals(0,BigDecimal.ONE.compareTo(issued(discoveredDocument)));
    }

    @Test void unknownChangedOrStaleMaterialRequestsCannotEnterTheKnownMaterialBatch(){
        var task=task();var unknown=task.discovery.request(task.segment,new ProductionMaterialDiscoveryContracts.Request(task.version(),"unknown-batch-"+task.segment));
        assertThrows(ApiException.class,()->batches.issue(new Request("unknown-submit-"+UUID.randomUUID(),List.of(),List.of(
                new Discovery(unknown.requestId(),unknown.version(),List.of(material(task,task.world.warehouseId(),"1")))),null)));
        task.discovery.cancel(unknown.requestId(),new ProductionMaterialDiscoveryContracts.Request(unknown.version(),"cancel-unknown-"+task.segment));
        var pending=suggest(task);
        assertThrows(ApiException.class,()->batches.issue(new Request("stale-submit-"+UUID.randomUUID(),List.of(),List.of(
                new Discovery(pending.requestId(),pending.version()+1,List.of(material(task,task.world.warehouseId(),"1")))),null)));
        assertThrows(ApiException.class,()->batches.issue(new Request("changed-submit-"+UUID.randomUUID(),List.of(),List.of(
                new Discovery(pending.requestId(),pending.version(),List.of(new Material(task.world.goodsE(),null,task.world.unitId(),task.world.warehouseId(),BigDecimal.ONE)))),null)));
        assertEquals("PENDING",task.discovery.detail(pending.requestId()).status());
        var actor=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        var workshopOnly=new AuthUser(actor.getId(),actor.getEmployeeId(),actor.getUsername(),Set.of("production_execution:view","production_execution:start"),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(workshopOnly,null,workshopOnly.getAuthorities()));
        assertThrows(ApiException.class,()->batches.issue(new Request("workshop-denied-"+UUID.randomUUID(),List.of(),List.of(
                new Discovery(pending.requestId(),pending.version(),List.of(material(task,task.world.warehouseId(),"1")))),null)));
        assertEquals(0,count("SELECT count(*) FROM production_material_demands WHERE execution_segment_id=?",task.segment));
    }

    @Test void concurrentSameKeySubmissionsHaveOneConfigurationAndOneIssue() throws Exception {
        var task=task();var pending=suggest(task);task.receive(task.world.goodsD(),"4");
        var request=new Request("concurrent-known-"+UUID.randomUUID(),List.of(),List.of(
                new Discovery(pending.requestId(),pending.version(),List.of(material(task,task.world.warehouseId(),"2")))),null);
        var authentication=SecurityContextHolder.getContext().getAuthentication();CountDownLatch start=new CountDownLatch(1);
        try(var pool=Executors.newFixedThreadPool(2)) {
            var operation=(java.util.concurrent.Callable<StockDocIssueBatchResponse>)()->{SecurityContextHolder.getContext().setAuthentication(authentication);
                try{start.await();return batches.issue(request);}finally{SecurityContextHolder.clearContext();}};
            var first=pool.submit(operation);var second=pool.submit(operation);start.countDown();
            var a=first.get(90,TimeUnit.SECONDS);var b=second.get(90,TimeUnit.SECONDS);
            assertEquals(1,a.issuedCount()+b.issuedCount());assertNotEquals(a.replayed(),b.replayed());
        }
        assertEquals(1,count("SELECT count(*) FROM production_draw_issue_batches WHERE idempotency_key=?",request.idempotencyKey()));
        assertEquals(1,count("SELECT count(*) FROM production_material_stock_postings WHERE demand_id IN(SELECT id FROM production_material_demands WHERE execution_segment_id=?) AND posting_type='ISSUE'",task.segment));
    }

    private ProductionMaterialDiscoveryEndToEndTest task(){var result=new ProductionMaterialDiscoveryEndToEndTest();beans.autowireBean(result);result.prepare();return result;}
    private BigDecimal issued(UUID document){return db.queryForObject("SELECT SUM(issued_qty) FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",BigDecimal.class,document);}
    private void reverse(ProductionMaterialDiscoveryEndToEndTest task,UUID document,String prefix){
        var request=new StockDocIssueRequest();request.setIdempotencyKey(prefix+document);request.setReason("核对后取消发料");
        request.setLines(db.query("SELECT id,issued_qty FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",(rs,index)->{
            var line=new StockDocIssueRequest.Line();line.setItemId(rs.getObject(1,UUID.class));line.setQty(rs.getBigDecimal(2));return line;},document));
        task.stock.reverseIssue(document,request);
    }
    private UUID legacyDraw(ProductionMaterialDiscoveryEndToEndTest task){
        task.plan=ReflectionTestUtils.invokeMethod(task.fixture,"approvedPlan",task.world,task.world.goodsB(),"1","1");
        var packages=beans.getBean(com.uten.imp.features.production.mrp.ProductionPlanningPackageService.class);
        var preview=packages.preview(task.plan,task.world.warehouseId());
        var command=new com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest();
        command.setWarehouseId(task.world.warehouseId());command.setIdempotencyKey("legacy-package-"+task.plan);
        command.setPreviewFingerprint(preview.fingerprint());command.setGeneratePurchaseRequest(false);
        packages.confirm(task.plan,command);task.fixture.confirmFullKitRoutes(task.plan);
        task.segment=db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",UUID.class,task.plan);
        List<UUID> documents=db.queryForList("SELECT document_id FROM production_planning_package_documents WHERE execution_segment_id=? AND document_type='DRAW'",UUID.class,task.segment);
        task.fixture.requestWorkshopDraws("legacy-batch-"+task.plan,documents);
        return documents.getFirst();
    }
    private ProductionMaterialDiscoveryContracts.Detail suggest(ProductionMaterialDiscoveryEndToEndTest task){
        return task.discovery.request(task.segment,new ProductionMaterialDiscoveryContracts.Request(task.version(),"known-material-"+UUID.randomUUID(),
                List.of(new ProductionMaterialDiscoveryContracts.RequestedMaterial(task.world.goodsD(),null,task.world.unitId(),null))));
    }
    private Material material(ProductionMaterialDiscoveryEndToEndTest task,UUID warehouse,String qty){return new Material(task.world.goodsD(),null,task.world.unitId(),warehouse,new BigDecimal(qty));}
    private UUID leaf(ProductionMaterialDiscoveryEndToEndTest task){UUID id=UUID.randomUUID();db.update("INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",id,"BATCH-"+id,"批量实际料仓",task.world.warehouseId());return id;}
    private int count(String sql,Object argument){return db.queryForObject(sql,Integer.class,argument);}
}
