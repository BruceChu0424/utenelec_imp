package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.PreplanFutureSupplyTransferService;
import com.uten.imp.features.production.analysis.PreplanFutureSupplyTransfer;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class PreplanPrivateFutureTransferEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired PreplanFutureSupplyTransferService transfers;
    @Autowired PurchaseOrderService purchases;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired com.uten.imp.features.subcontract.order.SubcontractOrderService subcontractOrders;
    @Autowired com.uten.imp.features.subcontract.receipt.SubcontractReceiptService subcontractReceipts;
    @Autowired com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService subcontractIssues;
    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementInspectionService inspection;
    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService iqc;
    @Autowired com.uten.imp.features.production.execution.ProductionExecutionSegmentService segments;
    FullChainEndToEndTest fixture;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void logout(){org.springframework.security.core.context.SecurityContextHolder.clearContext();}

    @Test void privateFortyIsReceivedBeforeOriginalSixtyWithoutTouchingAnExistingPublicNineHundredClaim() {
        var c=scenario("private-and-public");
        AnalysisView a=preview(c,"A","100");var original=order(c,a,"1000",BusinessTime.today().plusDays(2));
        AnalysisView d=preview(c,"D","900");var dm=material(d,c.material());
        d=commands.claimSharedFuture(d.analysisId(),new ClaimSharedFutureRequest(d.version(),d.fingerprint(),"private-public-claim-"+d.analysisId(),List.of(dm.actionGroupKey())));
        AnalysisView b=preview(c,"B","100");
        var candidate=transfers.sources(b.analysisId(),material(b,c.material()).materialLineId()).getFirst();
        qty("100",candidate.availableQty());qty("100",candidate.targetUncoveredQty());
        var request=request(candidate,material(b,c.material()).materialLineId(),"40","private-transfer-"+b.analysisId(),false);
        b=transfers.create(b.analysisId(),request);transfers.create(b.analysisId(),request);
        qty("40",material(analyses.detail(a.analysisId()),c.material()).additionalSupplyRecommendedQty());
        qty("60",material(b,c.material()).additionalSupplyRecommendedQty());
        qty("100",material(b,c.material()).demandSupplyGapQty());qty("0",material(b,c.material()).exactPeggedQty());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_reservations WHERE goods_id=?",Integer.class,c.material()));
        assertEquals(1,transfers.list(b.analysisId(),null).size());
        var replenishment=transfers.replenishmentByKey(a.analysisId(),request.idempotencyKey());qty("40",replenishment.remainingSupplementQty());assertTrue(replenishment.canOverSupply());
        qty("100",db.queryForObject("SELECT allocated_qty FROM preplan_supply_action_allocations WHERE id=?",BigDecimal.class,original.allocation()));
        qty("900",db.queryForObject("SELECT approved_capacity_qty FROM v_preplan_public_surplus_source_state WHERE source_action_id=?",BigDecimal.class,original.action()));
        assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("UPDATE purchase_order_items SET qty=qty-1 WHERE id=?",original.item()));
        assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("UPDATE purchase_orders SET status=0 WHERE id=(SELECT order_id FROM purchase_order_items WHERE id=?)",original.item()));
        assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("UPDATE preplan_supply_actions SET status='CANCELLED',cancelled_by=?,cancelled_at=now(),cancellation_reason='不能丢失目标承诺' WHERE id=?",c.world().superAdminUserId(),original.action()));
        UUID sourceAnalysisId=a.analysisId();
        assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("UPDATE production_material_analyses SET status='CANCELLED' WHERE id=?",sourceAnalysisId));

        receive(c,original.item(),"20","first");
        var partialB=material(analyses.detail(b.analysisId()),c.material());qty("20",partialB.exactPeggedQty());qty("60",partialB.additionalSupplyRecommendedQty());
        var state=transfers.list(b.analysisId(),null).getFirst();qty("20",state.receivedQty());qty("20",state.remainingQty());
        qty("0",material(analyses.detail(a.analysisId()),c.material()).exactPeggedQty());qty("0",material(analyses.detail(d.analysisId()),c.material()).exactPeggedQty());
        receive(c,original.item(),"980","rest");
        qty("40",material(analyses.detail(b.analysisId()),c.material()).exactPeggedQty());qty("60",material(analyses.detail(b.analysisId()),c.material()).additionalSupplyRecommendedQty());
        qty("60",material(analyses.detail(a.analysisId()),c.material()).exactPeggedQty());qty("900",material(analyses.detail(d.analysisId()),c.material()).exactPeggedQty());
        state=transfers.list(b.analysisId(),null).getFirst();qty("40",state.receivedQty());qty("0",state.remainingQty());assertEquals("RECEIVED",state.status());
        var source=analyses.detail(a.analysisId());var am=material(source,c.material());
        commands.notifySupply(source.analysisId(),new NotifyRequest(source.version(),source.fingerprint(),"private-source-replenish-"+source.analysisId(),"BUY",List.of(am.materialLineId()),List.of(),null));
        UUID replacement=ReflectionTestUtils.invokeMethod(fixture,"approveExistingAnalysisPurchase",c.world(),source.analysisId(),c.material());
        qty("40",db.queryForObject("SELECT qty FROM purchase_order_items WHERE id=?",BigDecimal.class,replacement));receive(c,replacement,"40","source-replenished");
        qty("100",material(analyses.detail(a.analysisId()),c.material()).exactPeggedQty());qty("40",material(analyses.detail(b.analysisId()),c.material()).exactPeggedQty());
        qty("900",material(analyses.detail(d.analysisId()),c.material()).exactPeggedQty());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM preplan_material_reallocations WHERE from_analysis_id=?",Integer.class,a.analysisId()));
    }

    @Test void fiftyPreviouslyReceivedLeavesOnlyFiftyTransferableAndOnlyTheUnreceivedPartCanBeCancelled() {
        var c=scenario("private-partial-cancel");AnalysisView a=preview(c,"A","100");var original=order(c,a,"100",BusinessTime.today().plusDays(2));
        receive(c,original.item(),"50","prior");AnalysisView b=preview(c,"B","100");
        var candidate=transfers.sources(b.analysisId(),material(b,c.material()).materialLineId()).getFirst();qty("50",candidate.availableQty());qty("50",candidate.receivedQty());
        var request=request(candidate,material(b,c.material()).materialLineId(),"40","private-partial-"+b.analysisId(),false);transfers.create(b.analysisId(),request);
        receive(c,original.item(),"20","assigned-first");var state=transfers.list(b.analysisId(),null).getFirst();
        qty("50",material(analyses.detail(a.analysisId()),c.material()).exactPeggedQty());qty("20",state.receivedQty());qty("20",state.remainingQty());
        var tooMuch=new PreplanFutureSupplyTransfer.Cancel(new BigDecimal("21"),state.sourceVersion(),state.sourceFingerprint(),state.targetVersion(),state.targetFingerprint(),"只能取消未收部分","private-cancel-too-much-"+state.id());
        assertThrows(ApiException.class,()->transfers.cancel(state.targetAnalysisId(),state.id(),tooMuch));
        var cancel=new PreplanFutureSupplyTransfer.Cancel(new BigDecimal("20"),state.sourceVersion(),state.sourceFingerprint(),state.targetVersion(),state.targetFingerprint(),"其余未收份额返回原计划","private-cancel-"+state.id());
        transfers.cancel(b.analysisId(),state.id(),cancel);transfers.cancel(b.analysisId(),state.id(),cancel);
        qty("80",db.queryForObject("SELECT fn_preplan_allocation_admitted_qty(?)",BigDecimal.class,original.allocation()));
        qty("80",material(analyses.detail(b.analysisId()),c.material()).additionalSupplyRecommendedQty());
        receive(c,original.item(),"30","original-rest");qty("80",material(analyses.detail(a.analysisId()),c.material()).exactPeggedQty());qty("20",material(analyses.detail(b.analysisId()),c.material()).exactPeggedQty());
        var result=transfers.list(a.analysisId(),null).getFirst();qty("20",result.cancelledQty());qty("20",result.receivedQty());qty("0",result.remainingQty());
        UUID reader=fixture.createUserWithPerms(c.world(),"private-progress-reader","production_material_analysis:view","production_material_analysis:notify","production_plan:view:all");fixture.loginAs(reader);
        assertFalse(transfers.list(a.analysisId(),null).getFirst().canCancel());qty("20",transfers.replenishment(a.analysisId(),result.id()).remainingSupplementQty());
        assertThrows(ApiException.class,()->transfers.cancel(b.analysisId(),result.id(),cancel));
    }

    @Test void latePrivateSupplyRemainsVisibleAndNeedsExplicitAcceptance() {
        var c=scenario("private-late");var a=preview(c,"A","100");order(c,a,"100",BusinessTime.today().plusDays(20));
        var b=preview(c,"B","100");var bm=material(b,c.material());var candidate=transfers.sources(b.analysisId(),bm.materialLineId()).getFirst();assertTrue(candidate.lateOrUnknown());
        assertThrows(ApiException.class,()->transfers.create(b.analysisId(),request(candidate,bm.materialLineId(),"40","private-late-denied-"+b.analysisId(),false)));
        var accepted=transfers.create(b.analysisId(),request(candidate,bm.materialLineId(),"40","private-late-accepted-"+b.analysisId(),true));
        qty("0",material(accepted,c.material()).exactPeggedQty());qty("60",material(accepted,c.material()).additionalSupplyRecommendedQty());
        assertTrue(transfers.list(b.analysisId(),null).getFirst().allowLateSupply());
        UUID workshop=UUID.randomUUID(),worker=UUID.randomUUID();
        UUID production=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD'",UUID.class);
        db.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES(?,?,?,?,'二级班组')",workshop,"FUT-WORK-"+workshop,"在途等待车间",production);
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')",worker,"FUT-EMP-"+worker,"在途等待负责人",workshop);
        var plan=commands.issueWorkshopPlans(accepted.analysisId(),new IssueWorkshopPlansRequest(accepted.version(),accepted.fingerprint(),"future-waiting-plan-"+accepted.analysisId(),c.world().warehouseId(),BusinessTime.today(),null,true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,bm.analysisLineId(),new BigDecimal("100"),BusinessTime.today(),null,workshop,null,worker,null,null)))).plans().getFirst();
        UUID segment=plan.segmentIds().getFirst();assertEquals("WAITING",db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?",String.class,segment));
        long version=db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);
        assertThrows(ApiException.class,()->segments.start(plan.planId(),segment,new com.uten.imp.features.production.execution.SegmentTransitionRequest(version,"future-cannot-start-"+segment)));
    }

    @org.junit.jupiter.params.ParameterizedTest
    @org.junit.jupiter.params.provider.ValueSource(strings={"20","40"})
    void replacementAlreadyArrangedAllowsCancellationIntoPublicFutureWithoutRestoringAnExcessPrivateShare(String replacementQty) {
        var c=scenario("private-cancel-after-replenish-"+replacementQty);var a=preview(c,"A","100");var original=order(c,a,"100",BusinessTime.today().plusDays(2));
        var b=preview(c,"B","100");var bm=material(b,c.material());var candidate=transfers.sources(b.analysisId(),bm.materialLineId()).getFirst();
        transfers.create(b.analysisId(),request(candidate,bm.materialLineId(),"40","private-replenish-transfer-"+b.analysisId(),false));
        var before=transfers.list(a.analysisId(),null).getFirst();assertTrue(before.canCancel());qty("40",before.cancelableQty());
        var source=analyses.detail(a.analysisId());var am=material(source,c.material());
        commands.notifySupply(source.analysisId(),new NotifyRequest(source.version(),source.fingerprint(),"private-replenish-arranged-"+a.analysisId(),"BUY",List.of(am.materialLineId()),List.of(),
                List.of(new SupplyQuantityInput(null,am.materialLineId(),new BigDecimal(replacementQty),BigDecimal.ZERO))));
        var state=transfers.list(a.analysisId(),null).getFirst();assertTrue(state.canCancel());qty("40",state.cancelableQty());qty("40",state.remainingQty());
        qty(new BigDecimal("40").subtract(new BigDecimal(replacementQty)).toPlainString(),state.cancelRestoreToSourceQty());qty(replacementQty,state.cancelPublicReleaseQty());
        var cancel=new PreplanFutureSupplyTransfer.Cancel(new BigDecimal("40"),state.sourceVersion(),state.sourceFingerprint(),state.targetVersion(),state.targetFingerprint(),"原计划已有补供不能重复归属","private-replenish-cancel-"+state.id());
        assertThrows(ApiException.class,()->transfers.cancel(a.analysisId(),state.id(),cancel));
        var accepted=new PreplanFutureSupplyTransfer.Cancel(cancel.qty(),cancel.sourceVersion(),cancel.sourceFingerprint(),cancel.targetVersion(),cancel.targetFingerprint(),cancel.reason(),cancel.idempotencyKey(),true);
        transfers.cancel(a.analysisId(),state.id(),accepted);transfers.cancel(a.analysisId(),state.id(),accepted);
        qty("0",transfers.list(b.analysisId(),null).getFirst().remainingQty());
        String originalRemaining=new BigDecimal("100").subtract(new BigDecimal(replacementQty)).toPlainString();
        qty(originalRemaining,db.queryForObject("SELECT fn_preplan_allocation_admitted_qty(?)",BigDecimal.class,original.allocation()));
        qty(originalRemaining,db.queryForObject("SELECT fn_preplan_future_source_available_qty(?)",BigDecimal.class,original.allocation()));
        qty(replacementQty,db.queryForObject("SELECT public_release_qty FROM preplan_future_supply_transfer_cancellations WHERE transfer_id=?",BigDecimal.class,state.id()));
        qty("0",material(analyses.detail(a.analysisId()),c.material()).additionalSupplyRecommendedQty());
        var d=preview(c,"D",replacementQty);var dm=material(d,c.material());qty(replacementQty,dm.publicSurplusRemainingQty());
        commands.claimSharedFuture(d.analysisId(),new ClaimSharedFutureRequest(d.version(),d.fingerprint(),"private-cancel-public-claim-"+d.analysisId(),List.of(dm.actionGroupKey())));
        receive(c,original.item(),"100","released-public-received");
        qty(originalRemaining,material(analyses.detail(a.analysisId()),c.material()).exactPeggedQty());qty(replacementQty,material(analyses.detail(d.analysisId()),c.material()).exactPeggedQty());
        qty("0",material(analyses.detail(b.analysisId()),c.material()).exactPeggedQty());
        UUID replacement=ReflectionTestUtils.invokeMethod(fixture,"approveExistingAnalysisPurchase",c.world(),a.analysisId(),c.material());
        receive(c,replacement,replacementQty,"replacement-received");qty("100",material(analyses.detail(a.analysisId()),c.material()).exactPeggedQty());
    }

    @Test void leafSubcontractPrivateShareReceivesFirstAfterRealSupplierIssueAndQualifiedReturn() {
        var c=scenario("private-leaf-subcontract");db.update("UPDATE goods SET source_type='委外' WHERE id=?",c.material());
        var a=preview(c,"A","100");var am=material(a,c.material());
        commands.notifySupply(a.analysisId(),new NotifyRequest(a.version(),a.fingerprint(),"future-sc-notify-"+a.analysisId(),"SUBCONTRACT",List.of(am.materialLineId()),List.of(),null));
        UUID application=db.queryForObject("SELECT allocation.external_item_id FROM preplan_supply_actions action JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id WHERE action.analysis_id=? AND action.route='SUBCONTRACT'",UUID.class,a.analysisId());
        UUID orderItem=orderSubcontract(c,application,"100");
        var b=preview(c,"B","100");var bm=material(b,c.material());var candidate=transfers.sources(b.analysisId(),bm.materialLineId()).getFirst();
        assertEquals("SUBCONTRACT",candidate.route());qty("100",candidate.availableQty());
        transfers.create(b.analysisId(),request(candidate,bm.materialLineId(),"40","future-sc-private-"+b.analysisId(),false));
        assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("UPDATE subcontract_order_items SET qty=qty-1 WHERE id=?",orderItem));
        receiveSubcontract(c,orderItem,"20");qty("20",material(analyses.detail(b.analysisId()),c.material()).exactPeggedQty());qty("0",material(analyses.detail(a.analysisId()),c.material()).exactPeggedQty());
        qty("60",material(analyses.detail(b.analysisId()),c.material()).additionalSupplyRecommendedQty());
        receiveSubcontract(c,orderItem,"80");qty("40",material(analyses.detail(b.analysisId()),c.material()).exactPeggedQty());qty("60",material(analyses.detail(a.analysisId()),c.material()).exactPeggedQty());
    }

    @Test void concurrentTargetsCannotTransferTheSamePrivateCapacityTwice() throws Exception {
        var c=scenario("private-concurrent");var a=preview(c,"A","100");var original=order(c,a,"100",BusinessTime.today().plusDays(2));
        var b=preview(c,"B","100");var d=preview(c,"D","100");
        var bs=transfers.sources(b.analysisId(),material(b,c.material()).materialLineId()).getFirst();
        var ds=transfers.sources(d.analysisId(),material(d,c.material()).materialLineId()).getFirst();
        var br=request(bs,material(b,c.material()).materialLineId(),"60","private-race-b-"+b.analysisId(),false);
        var dr=request(ds,material(d,c.material()).materialLineId(),"60","private-race-d-"+d.analysisId(),false);
        var start=new java.util.concurrent.CountDownLatch(1);var pool=java.util.concurrent.Executors.newFixedThreadPool(2);
        try {
            var first=pool.submit(()->raceCreate(c,b.analysisId(),br,start));var second=pool.submit(()->raceCreate(c,d.analysisId(),dr,start));start.countDown();
            var results=List.of(first.get(60,java.util.concurrent.TimeUnit.SECONDS),second.get(60,java.util.concurrent.TimeUnit.SECONDS));
            assertEquals(1,results.stream().filter(Boolean.TRUE::equals).count());
            assertEquals(1,db.queryForObject("SELECT count(*) FROM preplan_future_supply_transfers WHERE source_allocation_id=?",Integer.class,original.allocation()));
            qty("40",db.queryForObject("SELECT fn_preplan_future_source_available_qty(?)",BigDecimal.class,original.allocation()));
        } finally {pool.shutdownNow();}
    }
    private boolean raceCreate(Scenario c,UUID target,PreplanFutureSupplyTransfer.Create request,java.util.concurrent.CountDownLatch start) throws Exception {
        fixture.loginAs(c.world().superAdminUserId());try {start.await();transfers.create(target,request);return true;}
        catch(ApiException conflict){assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT,conflict.getCode());return false;}
        finally {org.springframework.security.core.context.SecurityContextHolder.clearContext();}
    }

    private Scenario scenario(String label){var w=fixture.seedWorld(label);fixture.loginAs(w.superAdminUserId());UUID product=UUID.randomUUID(),material=UUID.randomUUID();fixture.insertGoods(product,"FUT-P-"+product,"在途归属产品","自制",w.unitId(),w.unitLegacy());fixture.insertGoods(material,"FUT-M-"+material,"在途归属材料","采购",w.unitId(),w.unitLegacy());fixture.insertBom(product,material,"1");db.update("UPDATE goods SET default_supplier_id=? WHERE id=?",w.supplierId(),material);return new Scenario(w,product,material);}
    private AnalysisView preview(Scenario c,String label,String quantity){fixture.loginAs(c.world().superAdminUserId());String route="委外".equals(db.queryForObject("SELECT source_type FROM goods WHERE id=?",String.class,c.material()))?"SUBCONTRACT":"BUY";var view=analyses.preview(new PreviewRequest(null,null,null,c.world().warehouseId(),"future-preview-"+c.product()+label,List.of(new PreviewItem("OTHER",null,c.product(),null,c.world().unitId(),"future-"+c.product()+label,"私有在途与公共在途独立",BusinessTime.today().plusDays(10),new BigDecimal(quantity)))));return analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"future-route-"+view.analysisId(),view.flatMaterials().stream().filter(MaterialView::actionable).map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(c.material())?route:"MAKE",null)).toList()));}
    private Ordered order(Scenario c,AnalysisView view,String quantity,LocalDate eta){
        var material=material(view,c.material());commands.notifySupply(view.analysisId(),new NotifyRequest(view.version(),view.fingerprint(),"future-notify-"+view.analysisId(),"BUY",List.of(material.materialLineId()),List.of(),null));
        var source=db.queryForMap("SELECT action.id action_id,allocation.id allocation_id,allocation.external_item_id FROM preplan_supply_actions action JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id WHERE action.analysis_id=? AND action.operation_type='SUPPLY' AND action.route='BUY'",view.analysisId());
        var order=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();order.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture,"activeSettlementMethodId"));order.setBillDate(BusinessTime.today());order.setSupplierId(c.world().supplierId());order.setCurrencyId(c.world().currencyId());order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);
        com.uten.imp.features.purchase.order.dto.OrderItemLine line=ReflectionTestUtils.invokeMethod(fixture,"ma65OrderLine",c.world(),source.get("external_item_id"),c.material(),quantity);line.setDeliverDate(eta);order.setItems(List.of(line));purchases.createBatch(order);
        UUID item=db.queryForObject("SELECT source.order_item_id FROM purchase_order_item_sources source WHERE source.request_item_id=?",UUID.class,source.get("external_item_id"));UUID id=db.queryForObject("SELECT order_id FROM purchase_order_items WHERE id=?",UUID.class,item);
        UUID reviewer=ReflectionTestUtils.invokeMethod(fixture,"createApprover",c.world());finance.submit("PURCHASE",id);fixture.loginAs(reviewer);ReflectionTestUtils.invokeMethod(fixture,"approvePendingFinance","PURCHASE",id);fixture.loginAs(c.world().superAdminUserId());return new Ordered((UUID)source.get("action_id"),(UUID)source.get("allocation_id"),item);
    }
    private void receive(Scenario c,UUID orderItem,String quantity,String suffix){fixture.loginAs(c.world().superAdminUserId());ReflectionTestUtils.invokeMethod(fixture,"receiveAndPassPurchase",c.world(),orderItem,c.material(),new BigDecimal(quantity),"future-receive-"+orderItem+suffix);fixture.loginAs(c.world().superAdminUserId());}
    private UUID orderSubcontract(Scenario c,UUID applicationItem,String quantity) {
        var w=c.world();BigDecimal amount=new BigDecimal(quantity);
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,c.material(),quantity);
        var order=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        order.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture,"activeSettlementMethodId"));order.setBillDate(BusinessTime.today());order.setSupplierId(w.supplierId());order.setWarehouseId(w.warehouseId());order.setCurrencyId(w.currencyId());order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);
        var line=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();line.setGoodsId(c.material());line.setApplicationItemId(applicationItem);line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(amount);line.setPrice(new BigDecimal("30"));line.setAmountOriginal(amount.multiply(new BigDecimal("30")));line.setAmountLocal(line.getAmountOriginal());line.setDeliverDate(BusinessTime.today().plusDays(2));order.setItems(List.of(line));
        UUID orderId=subcontractOrders.create(order).getId();UUID orderItem=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",UUID.class,orderId);
        UUID approver=ReflectionTestUtils.invokeMethod(fixture,"createApprover",w);finance.submit("SUBCONTRACT",orderId);fixture.loginAs(approver);ReflectionTestUtils.invokeMethod(fixture,"approvePendingFinance","SUBCONTRACT",orderId);fixture.loginAs(w.superAdminUserId());
        for(UUID issueId:db.queryForList("SELECT DISTINCT issue.id FROM subcontract_material_issues issue JOIN subcontract_material_issue_items item ON item.issue_id=issue.id WHERE item.order_item_id=? AND issue.status=0 AND NOT issue.is_deleted",UUID.class,orderItem)) {
            var detail=subcontractIssues.detail(issueId);var issue=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest();issue.setBillDate(detail.getBillDate());issue.setSupplierId(detail.getSupplierId());issue.setWarehouseId(w.warehouseId());issue.setWorkerId(detail.getWorkerId());issue.setDeliverDate(detail.getDeliverDate());
            issue.setItems(detail.getItems().stream().map(original->{var item=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine();item.setLineNo(original.getLineNo());item.setGoodsId(original.getGoodsId());item.setColorId(original.getColorId());item.setUnitId(original.getUnitId());item.setUnitRate(original.getUnitRate());item.setQty(original.getQty());item.setOrderItemId(original.getOrderItemId());item.setPlanItemId(original.getPlanItemId());item.setParentGoodsId(original.getParentGoodsId());item.setParentColorId(original.getParentColorId());return item;}).toList());subcontractIssues.update(issueId,issue);subcontractIssues.approve(issueId);
        }
        return orderItem;
    }
    private void receiveSubcontract(Scenario c,UUID orderItem,String quantity) {
        var w=c.world();fixture.loginAs(w.superAdminUserId());BigDecimal amount=new BigDecimal(quantity);
        var receipt=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();receipt.setBillDate(BusinessTime.today());receipt.setSupplierId(w.supplierId());receipt.setWarehouseId(w.warehouseId());receipt.setCurrencyId(w.currencyId());receipt.setExchangeRate(BigDecimal.ONE);receipt.setTaxRate(BigDecimal.ZERO);receipt.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture,"activeSettlementMethodId"));
        var line=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();line.setOrderItemId(orderItem);line.setGoodsId(c.material());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(amount);line.setPrice(new BigDecimal("30"));line.setAmountOriginal(amount.multiply(new BigDecimal("30")));line.setAmountLocal(line.getAmountOriginal());receipt.setItems(List.of(line));
        UUID receiptId=subcontractReceipts.create(receipt).getId();subcontractReceipts.approve(receiptId);UUID inspectionId=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='SUBCONTRACT' AND receipt_id=?",UUID.class,receiptId);
        inspection.dispose("SUBCONTRACT",receiptId,inspectionId,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS",null,"转拨委外合格","future-sc-iqc-"+receiptId));
        fixture.loginAs(ReflectionTestUtils.invokeMethod(fixture,"createIqcWarehouseConfirmer",w,"future-sc-"+receiptId));
        com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest confirmation=ReflectionTestUtils.invokeMethod(fixture,"latestIqcStockInRequest","SUBCONTRACT",receiptId,inspectionId,amount,"future-sc-stock-"+receiptId,"FUTURE-SC");iqc.confirm("SUBCONTRACT",receiptId,confirmation);fixture.loginAs(w.superAdminUserId());
    }
    private static PreplanFutureSupplyTransfer.Create request(PreplanFutureSupplyTransfer.Source source,UUID material,String quantity,String key,boolean late){return new PreplanFutureSupplyTransfer.Create(source.sourceAllocationId(),material,new BigDecimal(quantity),source.sourceVersion(),source.sourceFingerprint(),source.targetVersion(),source.targetFingerprint(),late,"按新计划调整未来供给归属",key);}
    private static MaterialView material(AnalysisView view,UUID goods){return view.flatMaterials().stream().filter(row->row.goodsId().equals(goods)&&row.level()==1).findFirst().orElseThrow();}
    private static void qty(String expected,BigDecimal actual){assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+", actual "+actual);}
    private record Scenario(FullChainEndToEndTest.World world,UUID product,UUID material){}
    private record Ordered(UUID action,UUID allocation,UUID item){}
}
