package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.*;

import static com.uten.imp.businesschain.AggregateMaterialOrderEndToEndTest.amount;
import static org.junit.jupiter.api.Assertions.*;

/** Independent action permissions and irreversible downstream facts remain authoritative. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class AggregateMaterialOrderingBoundaryEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    AggregateMaterialOrderEndToEndTest h;
    @BeforeEach void before(){h=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(h);h.before();}
    @AfterEach void after(){h.after();}

    @ParameterizedTest @ValueSource(booleans={false,true})
    void makeApprovalAuthorityIsRequiredOnlyForImmediateApprovalAndItsReplay(boolean approved){
        var c=makeCase();
        SubmitRequest intent=command(c,"MAKE","6",false,approved);
        Authentication owner=SecurityContextHolder.getContext().getAuthentication();
        without(owner,"production_plan:approve");
        if(approved){
            assertCode(ErrorCode.FORBIDDEN,()->h.writer.submit(c.analysis(),intent));
            assertEquals(0,h.count("SELECT count(*) FROM preplan_aggregate_batches WHERE analysis_id=?",c.analysis()));
            SecurityContextHolder.getContext().setAuthentication(owner);
        }
        var batch=h.writer.submit(c.analysis(),intent).batches().getFirst();
        Map<String,Object> before=facts(c,batch);
        without(owner,"production_plan:approve");
        if(approved)assertCode(ErrorCode.FORBIDDEN,()->h.writer.submit(c.analysis(),intent));
        else assertTrue(h.writer.submit(c.analysis(),intent).replayed());
        assertEquals(before,facts(c,batch));
        assertEquals(approved?1:0,h.db.queryForObject("SELECT status FROM production_plans WHERE id=?",Integer.class,batch.planId()));
        amount("6",h.db.queryForObject("SELECT SUM(qty) FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,batch.planId()));
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void cancellationChecksTheActualPlanStageBeforeMutatingAndReceiptReplayRemainsReadOnly(boolean approved){
        var c=makeCase();
        var batch=h.writer.submit(c.analysis(),command(c,"MAKE","6",false,approved)).batches().getFirst();
        Authentication owner=SecurityContextHolder.getContext().getAuthentication();
        CancelRequest cancel=cancel(c,"stage-cancel-");
        Map<String,Object> before=facts(c,batch);
        String permission=approved?"production_plan:reverse":"production_plan:delete";
        without(owner,permission);
        assertCode(ErrorCode.FORBIDDEN,()->h.writer.cancel(c.analysis(),action(batch),cancel));
        assertEquals(before,facts(c,batch));
        SecurityContextHolder.getContext().setAuthentication(owner);
        h.writer.cancel(c.analysis(),action(batch),cancel);
        Map<String,Object> cancelled=facts(c,batch);
        without(owner,permission);
        h.writer.cancel(c.analysis(),action(batch),cancel);
        assertEquals(cancelled,facts(c,batch),"Replaying an authorized receipt performs no second stage mutation");
        assertEquals(1,cancelEvents(batch));
        assertEquals("CANCELLED",h.db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=?",String.class,action(batch)));
    }

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void externalPublicExtraNeedsItsOwnAuthorityWhileNormalDemandAndReceiptReplayRemainAllowed(String route){
        var c=externalCase(route);
        SubmitRequest extra=command(c,route,"7",true,true);
        SubmitRequest ordinary=command(c,route,"6",false,true);
        Authentication owner=SecurityContextHolder.getContext().getAuthentication();
        without(owner,"production_material_analysis:over_supply");
        var denied=h.preview.preview(c.analysis(),h.request(c,List.of(h.input(c,c.material(),route,"7",true)))).groups().getFirst();
        assertNotNull(denied.blockedReason());assertTrue(denied.blockedReason().contains("超量下达权限"));
        amount("1",denied.publicExtraQty());
        assertCode(ErrorCode.CONFLICT,()->h.writer.submit(c.analysis(),extra));
        assertEquals(0,h.count("SELECT count(*) FROM preplan_aggregate_batches WHERE analysis_id=?",c.analysis()));
        var first=h.writer.submit(c.analysis(),ordinary).batches().getFirst();
        assertTrue(h.writer.submit(c.analysis(),ordinary).replayed());
        SecurityContextHolder.getContext().setAuthentication(owner);
        h.writer.cancel(c.analysis(),action(first),cancel(c,"ordinary-reset-"));
        SubmitRequest authorized=command(c,route,"7",true,true);
        var publicBatch=h.writer.submit(c.analysis(),authorized).batches().getFirst();
        Map<String,Object> before=facts(c,publicBatch);
        without(owner,"production_material_analysis:over_supply");
        assertTrue(h.writer.submit(c.analysis(),authorized).replayed());
        assertEquals(before,facts(c,publicBatch));
        amount("6",h.db.queryForObject("SELECT requested_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,action(publicBatch)));
        amount("1",h.db.queryForObject("SELECT public_surplus_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,action(publicBatch)));
    }

    @ParameterizedTest @ValueSource(booleans={true,false})
    void simultaneousWholeBatchCancellationsRestoreSourcesAndReverseTheDocumentOnlyOnce(boolean sameKey) throws Exception {
        var c=externalCase("BUY");
        var batch=h.writer.submit(c.analysis(),command(c,"BUY","6",false,true)).batches().getFirst();
        CancelRequest first=cancel(c,"parallel-cancel-");
        CancelRequest second=sameKey?first:new CancelRequest(first.version(),first.fingerprint(),"other-cancel-"+UUID.randomUUID(),first.reason());
        Authentication owner=SecurityContextHolder.getContext().getAuthentication();
        var barrier=new java.util.concurrent.CyclicBarrier(2);
        java.util.function.Function<CancelRequest,Object> execute=request->{
            var context=SecurityContextHolder.createEmptyContext();context.setAuthentication(owner);SecurityContextHolder.setContext(context);
            try {barrier.await(30,java.util.concurrent.TimeUnit.SECONDS);return h.writer.cancel(c.analysis(),action(batch),request);}
            catch(ApiException rejected){return rejected;}
            catch(Exception failure){throw new RuntimeException(failure);}
            finally {SecurityContextHolder.clearContext();}
        };
        try(var workers=java.util.concurrent.Executors.newFixedThreadPool(2)){
            var left=workers.submit(()->execute.apply(first));var right=workers.submit(()->execute.apply(second));
            List<Object> results=List.of(left.get(90,java.util.concurrent.TimeUnit.SECONDS),right.get(90,java.util.concurrent.TimeUnit.SECONDS));
            assertEquals(sameKey?2:1,results.stream().filter(AnalysisView.class::isInstance).count());
            if(!sameKey)assertEquals(ErrorCode.CONFLICT,results.stream().filter(ApiException.class::isInstance).map(ApiException.class::cast).findFirst().orElseThrow().getCode());
        }
        assertEquals(1,cancelEvents(batch));
        assertEquals(1,h.count("SELECT count(*) FROM production_material_analysis_commands WHERE analysis_id=? AND operation='AGGREGATE_CANCEL'",c.analysis()));
        assertEquals(-1,h.db.queryForObject("SELECT status FROM purchase_requests WHERE id=?",Integer.class,batch.documentId()));
        var restored=h.preview.preview(c.analysis(),h.request(c,List.of(h.input(c,c.material(),"BUY","0",false)))).groups().getFirst();
        amount("6",restored.remainingQty());amount("0",restored.orderedQty());
    }

    @Test void anotherPlannerWithRouteAuthorityCannotMutateOrReplayTheOwnersAnalysis(){
        var c=externalCase("BUY");
        SubmitRequest intent=command(c,"BUY","6",false,true);
        Authentication owner=SecurityContextHolder.getContext().getAuthentication();
        UUID other=h.fixture.createUserWithPerms(c.world(),"boundary-owner-"+UUID.randomUUID(),
                "production_material_analysis:view","production_material_analysis:manage","production_material_analysis:notify");
        h.fixture.loginAs(other);
        assertCode(ErrorCode.FORBIDDEN,()->h.writer.submit(c.analysis(),intent));
        SecurityContextHolder.getContext().setAuthentication(owner);
        var batch=h.writer.submit(c.analysis(),intent).batches().getFirst();
        CancelRequest cancellation=cancel(c,"owner-cancel-");
        Map<String,Object> before=facts(c,batch);
        h.fixture.loginAs(other);
        assertCode(ErrorCode.FORBIDDEN,()->h.writer.submit(c.analysis(),intent));
        assertCode(ErrorCode.FORBIDDEN,()->h.writer.cancel(c.analysis(),action(batch),cancellation));
        assertEquals(before,facts(c,batch));
        SecurityContextHolder.getContext().setAuthentication(owner);
        h.writer.cancel(c.analysis(),action(batch),cancellation);
        Map<String,Object> cancelled=facts(c,batch);
        h.fixture.loginAs(other);
        assertCode(ErrorCode.FORBIDDEN,()->h.writer.cancel(c.analysis(),action(batch),cancellation));
        assertEquals(cancelled,facts(c,batch));
    }

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void externalOrderingAndPartialPhysicalReceiptRejectWholeBatchCancelWithoutChangingFacts(String route){
        var c=externalCase(route);
        var batch=h.writer.submit(c.analysis(),command(c,route,"6",false,true)).batches().getFirst();
        UUID orderItem=placeExternalOrder(c,batch);
        assertExternalCancelRejected(c,batch,orderItem);
        UUID receipt=receiveExternal(c,route,orderItem,new BigDecimal("2"));
        amount("2",h.db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM preplan_analysis_stock_exact_pegs WHERE source_receipt_id=? AND beneficiary_analysis_id=?",BigDecimal.class,receipt,c.analysis()));
        assertExternalCancelRejected(c,batch,orderItem);
    }

    private void assertExternalCancelRejected(AggregateMaterialOrderEndToEndTest.Case c,BatchResult batch,UUID orderItem){
        CancelRequest cancellation=cancel(c,"external-used-");
        Map<String,Object> before=facts(c,batch);Map<String,Object> external=externalFacts(c,batch.route(),orderItem);
        assertCode(ErrorCode.CONFLICT,()->h.writer.cancel(c.analysis(),action(batch),cancellation));
        assertEquals(before,facts(c,batch));assertEquals(external,externalFacts(c,batch.route(),orderItem));
        assertEquals(0,cancelEvents(batch));
    }

    private AggregateMaterialOrderEndToEndTest.Case makeCase(){
        var c=h.create(false,false,"1");h.setRoute(c,c.material(),"MAKE");return c;
    }
    private AggregateMaterialOrderEndToEndTest.Case externalCase(String route){
        var c=h.create(false,false,"1");
        if("SUBCONTRACT".equals(route)){h.fixture.addSubcontractDirectMaterial(c.world(),c.material(),"1");h.setRoute(c,c.material(),route);}
        return c;
    }
    private SubmitRequest command(AggregateMaterialOrderEndToEndTest.Case c,String route,String quantity,boolean extra,boolean approve){
        var base=h.request(c,List.of(h.input(c,c.material(),route,quantity,extra)));
        var request=new com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.PreviewRequest(base.version(),base.fingerprint(),
                base.idempotencyKey(),base.warehouseId(),base.billDate(),base.deliveryDate(),approve,base.groups());
        return h.submit(h.preview.preview(c.analysis(),request),request);
    }
    private CancelRequest cancel(AggregateMaterialOrderEndToEndTest.Case c,String prefix){
        AnalysisView current=h.analyses.detail(c.analysis());return new CancelRequest(current.version(),current.fingerprint(),prefix+UUID.randomUUID(),"聚合下单边界回归");
    }
    private UUID action(BatchResult batch){return h.db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,batch.batchId());}
    private long cancelEvents(BatchResult batch){return h.count("SELECT count(*) FROM preplan_aggregate_batch_events WHERE batch_id=? AND event_type='CANCEL'",batch.batchId());}
    private Map<String,Object> facts(AggregateMaterialOrderEndToEndTest.Case c,BatchResult batch){
        String document=switch(batch.route()){case "BUY"->"purchase_requests";case "SUBCONTRACT"->"subcontract_applications";default->"production_plans";};
        UUID documentId=batch.planId()==null?batch.documentId():batch.planId();
        Map<String,Object> facts=new LinkedHashMap<>();
        facts.put("analysis",h.db.queryForMap("SELECT version,fingerprint,status FROM production_material_analyses WHERE id=?",c.analysis()));
        facts.put("cancelReceipts",h.db.queryForList("SELECT to_jsonb(fact)::text FROM production_material_analysis_commands fact WHERE analysis_id=? AND operation='AGGREGATE_CANCEL' ORDER BY id",String.class,c.analysis()));
        facts.put("action",h.db.queryForObject("SELECT to_jsonb(fact)::text FROM preplan_supply_actions fact WHERE id=?",String.class,action(batch)));
        facts.put("batch",h.db.queryForObject("SELECT to_jsonb(fact)::text FROM preplan_aggregate_batches fact WHERE id=?",String.class,batch.batchId()));
        facts.put("allocations",h.db.queryForList("SELECT to_jsonb(fact)::text FROM preplan_supply_action_allocations fact WHERE action_id=? ORDER BY id",String.class,action(batch)));
        facts.put("events",h.db.queryForList("SELECT to_jsonb(fact)::text FROM preplan_aggregate_batch_events fact WHERE batch_id=? ORDER BY id",String.class,batch.batchId()));
        facts.put("document",h.db.queryForObject("SELECT to_jsonb(fact)::text FROM "+document+" fact WHERE id=?",String.class,documentId));
        facts.put("pegs",h.db.queryForList("SELECT to_jsonb(fact)::text FROM preplan_analysis_stock_exact_pegs fact WHERE beneficiary_analysis_id=? ORDER BY id",String.class,c.analysis()));
        facts.put("reservations",h.db.queryForList("SELECT to_jsonb(fact)::text FROM stock_reservations fact WHERE goods_id=? ORDER BY id",String.class,c.material()));
        return facts;
    }
    private Map<String,Object> externalFacts(AggregateMaterialOrderEndToEndTest.Case c,String route,UUID orderItem){
        String prefix="BUY".equals(route)?"purchase":"subcontract";
        return Map.of("order",h.db.queryForObject("SELECT to_jsonb(fact)::text FROM "+prefix+"_order_items fact WHERE id=?",String.class,orderItem),
                "receipts",h.db.queryForList("SELECT to_jsonb(fact)::text FROM "+prefix+"_receipt_items fact WHERE order_item_id=? ORDER BY id",String.class,orderItem),
                "stock",h.db.queryForList("SELECT to_jsonb(fact)::text FROM stock_movements fact WHERE goods_id=? ORDER BY id",String.class,c.material()));
    }

    private UUID placeExternalOrder(AggregateMaterialOrderEndToEndTest.Case c,BatchResult batch){
        if("BUY".equals(batch.route()))return ReflectionTestUtils.invokeMethod(h.fixture,"approveExistingAnalysisPurchase",c.world(),c.analysis(),c.material());
        UUID direct=h.fixture.ensureSubcontractDirectMaterial(c.world(),c.material());h.fixture.receiveSubcontractMaterial(c.world(),direct,"6");
        UUID applicationItem=h.db.queryForObject("SELECT id FROM subcontract_application_items WHERE application_id=? AND NOT is_deleted",UUID.class,batch.documentId());
        UUID order=ReflectionTestUtils.invokeMethod(h.fixture,"createSubcontractOrderFromApplication",c.world(),c.material(),applicationItem,"6");
        var finance=beans.getBean(com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService.class);
        finance.submit("SUBCONTRACT",order);
        UUID reviewer=ReflectionTestUtils.invokeMethod(h.fixture,"createApprover",c.world());h.fixture.loginAs(reviewer);
        h.fixture.approvePendingFinance("SUBCONTRACT",order);h.fixture.loginAs(c.world().superAdminUserId());
        UUID item=h.db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);
        h.fixture.drawAndIssueSubcontract(item,new BigDecimal("6"),"boundary-draw-"+item);return item;
    }
    private UUID receiveExternal(AggregateMaterialOrderEndToEndTest.Case c,String route,UUID orderItem,BigDecimal qty){
        UUID receipt;
        if("BUY".equals(route))receipt=ReflectionTestUtils.invokeMethod(h.fixture,"receiveAndPassPurchase",c.world(),orderItem,c.material(),qty,"boundary-receipt-"+UUID.randomUUID());
        else {
            var request=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();
            request.setBillDate(BusinessTime.today());request.setSupplierId(c.world().supplierId());request.setWarehouseId(c.world().warehouseId());
            request.setCurrencyId(c.world().currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
            request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(h.fixture,"activeSettlementMethodId"));
            var line=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();line.setOrderItemId(orderItem);line.setGoodsId(c.material());
            line.setUnitId(c.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(qty);line.setPrice(new BigDecimal("30"));request.setItems(List.of(line));
            var receipts=beans.getBean(com.uten.imp.features.subcontract.receipt.SubcontractReceiptService.class);
            receipt=receipts.create(request).getId();receipts.approve(receipt);
            UUID inspection=h.db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='SUBCONTRACT' AND receipt_id=?",UUID.class,receipt);
            beans.getBean(com.uten.imp.features.warehouse.inbound.ProcurementInspectionService.class).dispose("SUBCONTRACT",receipt,inspection,
                    new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS",null,"整批撤回边界验证","boundary-iqc-"+receipt));
            UUID confirmer=ReflectionTestUtils.invokeMethod(h.fixture,"createIqcWarehouseConfirmer",c.world(),"boundary-stock-"+receipt);h.fixture.loginAs(confirmer);
            com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest confirm=ReflectionTestUtils.invokeMethod(h.fixture,"latestIqcStockInRequest",
                    "SUBCONTRACT",receipt,inspection,qty,"boundary-stock-"+receipt,"BOUNDARY");
            beans.getBean(com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService.class).confirm("SUBCONTRACT",receipt,confirm);
        }
        h.fixture.loginAs(c.world().superAdminUserId());return receipt;
    }
    private void without(Authentication authentication,String permission){
        AuthUser owner=(AuthUser)authentication.getPrincipal();Set<String> grants=new HashSet<>(owner.getPermissions());grants.remove(permission);
        AuthUser actor=new AuthUser(owner.getId(),owner.getEmployeeId(),owner.getUsername(),grants,false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor,null,actor.getAuthorities()));
    }
    private void assertCode(ErrorCode code,org.junit.jupiter.api.function.Executable operation){
        ApiException failure=assertThrows(ApiException.class,operation);assertEquals(code,failure.getCode(),failure.getMessage());
    }
}
