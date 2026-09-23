package com.uten.imp.businesschain;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
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
import static org.junit.jupiter.api.Assertions.*;
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class PreplanPublicFutureReplenishmentEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    private FullChainEndToEndTest fixture;
    @BeforeEach void prepare() { fixture=new FullChainEndToEndTest();beans.autowireBean(fixture); }
    @Test void publicNineHundredCanBeClaimedInEditedBatchesThenOnlyOneHundredNeedsNewSupply() { run(false); }
    @Test void lateNineHundredNeedsExplicitAcceptanceWithoutChangingPlanDateOrReadyState() { run(true); }
    @Test void receivedAwaitingInspectionAndQualifiedAwaitingStockInCanStillBeNewlyClaimed() { run(false,true); }
    @Test void failedInspectedSupplyAllowsCancellingExistingClaimWithoutChangingSourceOrder() { run(false,true,true); }
    private void run(boolean late) { run(late,false,false); }
    private void run(boolean late,boolean claimAfterReceipt) { run(late,claimAfterReceipt,false); }
    private void run(boolean late,boolean claimAfterReceipt,boolean failAndCancel) {
        var w=fixture.seedWorld("public-future-"+late+"-"+claimAfterReceipt+"-"+failAndCancel);fixture.loginAs(w.superAdminUserId());
        UUID productA=UUID.randomUUID(),productB=UUID.randomUUID(),goods=UUID.randomUUID(),main=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,status) VALUES(?,?,?,'使用')",main,"PF-MAIN-"+main,"公共在途主仓");
        db.update("UPDATE warehouses SET parent_id=? WHERE id=?",main,w.warehouseId());
        fixture.insertGoods(productA,"PF-A-"+productA,"公共在途原计划","自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(productB,"PF-B-"+productB,"公共在途新计划","自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(goods,"PF-M-"+goods,"共享在途原料","采购",w.unitId(),w.unitLegacy());
        fixture.insertBom(productA,goods,"1");fixture.insertBom(productB,goods,"1");
        db.update("UPDATE goods SET default_supplier_id=? WHERE id=?",w.supplierId(),goods);
        LocalDate need=BusinessTime.today().plusDays(10),eta=BusinessTime.today().plusDays(late?20:5);
        AnalysisView a=preview(w,w.warehouseId(),productA,goods,"A","100",need);
        MaterialView am=material(a,goods);
        var notifiedA=commands.notifySupply(a.analysisId(),new NotifyRequest(a.version(),a.fingerprint(),"public-source-"+a.analysisId(),
                "BUY",List.of(am.materialLineId()),List.of(),List.of(new SupplyQuantityInput(null,am.materialLineId(),new BigDecimal("100"),BigDecimal.ZERO))));
        var source=db.queryForMap("SELECT action.id,allocation.external_item_id FROM preplan_supply_actions action JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id WHERE action.analysis_id=? AND action.route='BUY'",a.analysisId());
        UUID sourceAction=(UUID)source.get("id"),requestItem=(UUID)source.get("external_item_id");
        UUID sourceOrder=approveOrder(w,requestItem,goods,"1000",eta);
        PendingReceipt pending=claimAfterReceipt?receiveToInspection(w,sourceOrder,goods):null;
        qty("100",db.queryForObject("SELECT requested_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,sourceAction));
        qty("900",db.queryForObject("SELECT available_to_claim_qty FROM v_preplan_public_surplus_source_state WHERE source_action_id=?",BigDecimal.class,sourceAction));
        AnalysisView b=preview(w,main,productB,goods,"B","1000",need);MaterialView bm=material(b,goods);
        qty(late?"0":"900",bm.publicSurplusRemainingQty());qty(late?"900":"0",bm.lateSharedFutureAvailableQty());
        final UUID beforeReceiver=b.analysisId();
        var excessive=new ClaimSharedFutureRequest(b.version(),b.fingerprint(),"claim-public-too-large-"+beforeReceiver,
                List.of(bm.actionGroupKey()),List.of(new SharedFutureClaimQuantity(bm.actionGroupKey(),new BigDecimal("901"),sourceAction)),late);
        assertThrows(ApiException.class,()->commands.claimSharedFuture(beforeReceiver,excessive),"explicit 901 cannot silently claim only 900 or consume the original private 100");
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM preplan_supply_actions WHERE analysis_id=?",Integer.class,beforeReceiver));
        qty("900",db.queryForObject("SELECT available_to_claim_qty FROM v_preplan_public_surplus_source_state WHERE source_action_id=?",BigDecimal.class,sourceAction));
        String firstKey="claim-public-first-"+b.analysisId();
        ClaimSharedFutureRequest first=new ClaimSharedFutureRequest(b.version(),b.fingerprint(),firstKey,
                List.of(bm.actionGroupKey()),List.of(new SharedFutureClaimQuantity(bm.actionGroupKey(),new BigDecimal("400"),sourceAction)),late);
        if(late) {
            final UUID receiver=b.analysisId();
            var denied=new ClaimSharedFutureRequest(b.version(),b.fingerprint(),firstKey,List.of(bm.actionGroupKey()),first.quantities(),false);
            assertThrows(ApiException.class,()->commands.claimSharedFuture(receiver,denied));
            assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM preplan_supply_actions WHERE analysis_id=?",Integer.class,receiver));
        }
        b=commands.claimSharedFuture(b.analysisId(),first);commands.claimSharedFuture(b.analysisId(),first);
        if(failAndCancel) {
            var inspections=(com.uten.imp.features.warehouse.inbound.ProcurementInspectionService)ReflectionTestUtils.getField(fixture,"inspectionService");
            inspections.dispose("PURCHASE",pending.receiptId(),pending.inspectionId(),new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                    "FAIL",null,"实检整批不合格，撤回尚未取得实物的公共认领","public-pending-fail-"+pending.inspectionId()));
            qty("0",db.queryForObject("SELECT COALESCE((SELECT available_to_claim_qty FROM v_preplan_public_surplus_source_state WHERE source_action_id=?),0)",BigDecimal.class,sourceAction));
            b=analyses.detail(b.analysisId());
            UUID claim=db.queryForObject("SELECT id FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SHARED_FUTURE_CLAIM'",UUID.class,b.analysisId());
            var cancel=new CancelRequest(b.version(),b.fingerprint(),"public-failed-cancel-"+claim,"取消不合格未到供给认领");
            final AnalysisView failed=b;
            assertAll(
                ()->qty("1000",material(failed,goods).additionalSupplyRecommendedQty()),
                ()->{
                    var cancelled=commands.cancelAction(failed.analysisId(),claim,cancel);
                    commands.cancelAction(failed.analysisId(),claim,cancel);
                    qty("0",material(cancelled,goods).sharedFutureClaimedQty());qty("0",material(cancelled,goods).sharedFuturePendingQty());
                    qty("1000",material(cancelled,goods).shortageQty());qty("1000",material(cancelled,goods).additionalSupplyRecommendedQty());
                    qty("1000",db.queryForObject("SELECT qty FROM purchase_order_items WHERE id=?",BigDecimal.class,sourceOrder));
                    assertEquals("CANCELLED",db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=?",String.class,claim));
                    qty("400",db.queryForObject("SELECT requested_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,claim));
                    qty("0",db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",BigDecimal.class,goods));
                    var sourceAgain=analyses.detail(a.analysisId());
                    assertFalse(db.queryForObject("SELECT fn_preplan_action_has_shared_claims(?)",Boolean.class,sourceAction));
                    qty("100",material(sourceAgain,goods).additionalSupplyRecommendedQty());
                    commands.notifySupply(a.analysisId(),new NotifyRequest(sourceAgain.version(),sourceAgain.fingerprint(),"public-source-renotify-"+sourceAction,
                            "BUY",List.of(am.materialLineId()),List.of(),List.of(new SupplyQuantityInput(null,am.materialLineId(),new BigDecimal("100"),BigDecimal.ZERO))));
                    assertEquals("CANCELLED",db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=?",String.class,sourceAction));
                    assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SUPPLY'",Integer.class,a.analysisId()));
                    qty("100",db.queryForObject("SELECT requested_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,sourceAction));
                });
            return;
        }
        if(pending!=null) {
            passReceipt(w,pending);
            qty("500",db.queryForObject("SELECT available_to_claim_qty FROM v_preplan_public_surplus_source_state WHERE source_action_id=?",BigDecimal.class,sourceAction));
            qty("0",db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",BigDecimal.class,goods));
            b=analyses.detail(b.analysisId());
        }
        assertEquals(late,db.queryForObject("SELECT (result_payload->>'allowLateSupply')::boolean FROM production_material_analysis_commands WHERE analysis_id=? AND operation='CLAIM_SHARED_FUTURE' AND idempotency_key=?",Boolean.class,b.analysisId(),firstKey));
        assertEquals(late?1:0,db.queryForObject("SELECT jsonb_array_length(result_payload->'acceptedLateSources') FROM production_material_analysis_commands WHERE analysis_id=? AND operation='CLAIM_SHARED_FUTURE' AND idempotency_key=?",Integer.class,b.analysisId(),firstKey));
        qty("400",material(b,goods).sharedFutureClaimedQty());qty("400",material(b,goods).sharedFuturePendingQty());
        qty("600",material(b,goods).additionalSupplyRecommendedQty());qty("1000",material(b,goods).shortageQty());
        assertTrue(b.products().stream().filter(p->p.goodsId().equals(productB)).allMatch(p->p.readyNowQty().signum()==0));
        final UUID receiver=b.analysisId();
        var changed=new ClaimSharedFutureRequest(first.version(),first.fingerprint(),firstKey,first.actionGroupKeys(),
                List.of(new SharedFutureClaimQuantity(bm.actionGroupKey(),new BigDecimal("401"),sourceAction)),late);
        assertThrows(ApiException.class,()->commands.claimSharedFuture(receiver,changed));
        var second=new ClaimSharedFutureRequest(b.version(),b.fingerprint(),"claim-public-second-"+receiver,List.of(bm.actionGroupKey()),
                List.of(new SharedFutureClaimQuantity(bm.actionGroupKey(),new BigDecimal("500"),sourceAction)),late);
        b=commands.claimSharedFuture(receiver,second);
        qty("900",material(b,goods).sharedFutureClaimedQty());qty("900",material(b,goods).sharedFuturePendingQty());
        qty("100",material(b,goods).additionalSupplyRecommendedQty());qty("1000",material(b,goods).shortageQty());
        qty("0",db.queryForObject("SELECT available_to_claim_qty FROM v_preplan_public_surplus_source_state WHERE source_action_id=?",BigDecimal.class,sourceAction));
        assertEquals(need,db.queryForObject("SELECT delivery_date FROM production_material_analysis_items WHERE id=?",LocalDate.class,b.products().getFirst().analysisLineId()));
        var c=preview(w,main,productB,goods,"C","10",need);var cm=material(c,goods);
        assertThrows(ApiException.class,()->commands.claimSharedFuture(c.analysisId(),new ClaimSharedFutureRequest(c.version(),c.fingerprint(),"claim-public-unavailable-"+c.analysisId(),
                List.of(cm.actionGroupKey()),List.of(new SharedFutureClaimQuantity(cm.actionGroupKey(),BigDecimal.TEN,sourceAction)),late)));
        if(claimAfterReceipt) {
            // A later claim on a different source must not lose its own public
            // interval to the earlier 400+500 claims on the first source.
            var d=preview(w,w.warehouseId(),productA,goods,"D","10",need);var dm=material(d,goods);
            commands.notifySupply(d.analysisId(),new NotifyRequest(d.version(),d.fingerprint(),"independent-public-source-"+d.analysisId(),
                    "BUY",List.of(dm.materialLineId()),List.of(),List.of(new SupplyQuantityInput(null,dm.materialLineId(),BigDecimal.TEN,BigDecimal.ZERO))));
            var ds=db.queryForMap("SELECT action.id,allocation.external_item_id FROM preplan_supply_actions action JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id WHERE action.analysis_id=?",d.analysisId());
            approveOrder(w,(UUID)ds.get("external_item_id"),goods,"20",BusinessTime.today().plusDays(5));
            var receiverC=analyses.detail(c.analysisId());var receiverMaterial=material(receiverC,goods);
            commands.claimSharedFuture(c.analysisId(),new ClaimSharedFutureRequest(receiverC.version(),receiverC.fingerprint(),"independent-public-claim-"+c.analysisId(),
                    List.of(receiverMaterial.actionGroupKey()),List.of(new SharedFutureClaimQuantity(receiverMaterial.actionGroupKey(),BigDecimal.TEN,(UUID)ds.get("id"))),false));
            qty("10",db.queryForObject("SELECT fn_preplan_shared_action_pending_qty(id) FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SHARED_FUTURE_CLAIM'",BigDecimal.class,c.analysisId()));
            qty("900",db.queryForObject("SELECT SUM(fn_preplan_shared_action_pending_qty(id)) FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SHARED_FUTURE_CLAIM'",BigDecimal.class,receiver));
            qty("0",db.queryForObject("SELECT fn_preplan_shared_action_pending_qty(?)",BigDecimal.class,sourceAction));
        }
        var own=commands.notifySupply(receiver,new NotifyRequest(b.version(),b.fingerprint(),"public-residual-buy-"+receiver,"BUY",
                List.of(bm.materialLineId()),List.of(),List.of(new SupplyQuantityInput(null,bm.materialLineId(),new BigDecimal("100"),BigDecimal.ZERO))));
        var ownSource=db.queryForMap("SELECT action.id,allocation.external_item_id,allocation.allocated_qty FROM preplan_supply_actions action JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id WHERE action.analysis_id=? AND action.operation_type='SUPPLY'",receiver);
        qty("100",(BigDecimal)ownSource.get("allocated_qty"));
        UUID ownOrder=approveOrder(w,(UUID)ownSource.get("external_item_id"),goods,"100",BusinessTime.today().plusDays(5));
        fixture.loginAs(w.superAdminUserId());b=analyses.detail(receiver);
        qty("0",material(b,goods).additionalSupplyRecommendedQty());qty("900",material(b,goods).sharedFuturePendingQty());
        qty("1000", material(b, goods).externalFutureCoverageQty());
        qty("0", material(b, goods).internalCommittedOutputQty());
        var issued=commands.issueWorkshopPlans(receiver,new IssueWorkshopPlansRequest(b.version(),b.fingerprint(),"public-waiting-plan-"+receiver,
                main,BusinessTime.today(),need,true,List.of(new IssueWorkshopPlansRequest.IssuePlanLine(b.products().getFirst().analysisLineId(),new BigDecimal("1000")))));
        UUID plan=issued.plans().getFirst().planId();
        assertEquals("WAITING",db.queryForObject("SELECT status FROM production_execution_segments WHERE plan_id=?",String.class,plan));
        qty("0",db.queryForObject("SELECT COALESCE(SUM(reservation.qty-reservation.released_qty),0) FROM stock_reservations reservation JOIN production_material_demands demand ON demand.id=reservation.demand_id WHERE demand.plan_id=?",BigDecimal.class,plan));
        if(pending==null) receive(w,sourceOrder,goods,"900");else stockReceipt(w,pending,"900");
        fixture.loginAs(w.superAdminUserId());
        var partly=analyses.detail(receiver);qty("200",material(partly,goods).shortageQty());
        qty("100",material(partly,goods).sharedFuturePendingQty());qty("900",material(partly,goods).sharedFutureClaimedQty());
        qty("0",material(partly,goods).additionalSupplyRecommendedQty());
        // ADR-099「填多少下多少」：B 的需求已被 900 认领 + 100 自购全覆盖，A 先到的
        // 100 也不能替 B 完成认领——此时再填 100 一分都不会再绑到需求上(需求侧
        // 仍是自购的 100)，整个 100 走公共备货通道(超量下达权限由服务端自裁)。
        var duplicate=new NotifyRequest(partly.version(),partly.fingerprint(),"must-not-buy-shared-pending-"+receiver,"BUY",List.of(bm.materialLineId()),List.of(),
                List.of(new SupplyQuantityInput(null,bm.materialLineId(),new BigDecimal("100"),BigDecimal.ZERO)));
        var stocked=commands.notifySupply(receiver,duplicate);
        qty("0",material(stocked,goods).additionalSupplyRecommendedQty());qty("100",material(stocked,goods).sharedFuturePendingQty());
        qty("100",db.queryForObject("SELECT COALESCE(SUM(requested_qty),0) FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SUPPLY' AND status<>'CANCELLED'",BigDecimal.class,receiver));
        qty("100",db.queryForObject("SELECT COALESCE(SUM(public_surplus_qty),0) FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SUPPLY' AND status<>'CANCELLED'",BigDecimal.class,receiver));
        if(pending==null) receive(w,sourceOrder,goods,"100");else stockReceipt(w,pending,"100");
        fixture.loginAs(w.superAdminUserId());
        partly=analyses.detail(receiver);qty("100",material(partly,goods).shortageQty());
        qty("0",material(partly,goods).sharedFuturePendingQty());qty("900",material(partly,goods).sharedFutureClaimedQty());
        receive(w,ownOrder,goods,"100");fixture.loginAs(w.superAdminUserId());
        qty("0",material(analyses.detail(receiver),goods).shortageQty());
        qty("1100",db.queryForObject("SELECT SUM(qty) FROM stock_balances WHERE goods_id=?",BigDecimal.class,goods));
        assertFalse(db.queryForObject("SELECT EXISTS(SELECT 1 FROM production_execution_segments WHERE plan_id=? AND status='IN_PROGRESS')",Boolean.class,plan),"arrival must never start production");
    }
    private AnalysisView preview(FullChainEndToEndTest.World w,UUID warehouse,UUID product,UUID goods,String label,String amount,LocalDate need) {
        fixture.loginAs(w.superAdminUserId());
        var view=analyses.preview(new PreviewRequest(null,null,null,warehouse,"public-preview-"+product+label,
                List.of(new PreviewItem("OTHER",null,product,null,w.unitId(),"public-source-"+product+label,"公共在途认领",need,new BigDecimal(amount)))));
        return analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"public-route-"+view.analysisId(),
                view.flatMaterials().stream().filter(MaterialView::actionable).map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),row.goodsId().equals(goods)?"BUY":"MAKE",null)).toList()));
    }
    private UUID approveOrder(FullChainEndToEndTest.World w,UUID requestItem,UUID goods,String amount,LocalDate eta) {
        fixture.loginAs(w.superAdminUserId());
        var request=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture,"activeSettlementMethodId"));request.setBillDate(LocalDate.of(2026,1,15));
        request.setSupplierId(w.supplierId());request.setCurrencyId(w.currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        com.uten.imp.features.purchase.order.dto.OrderItemLine line=ReflectionTestUtils.invokeMethod(fixture,"ma65OrderLine",w,requestItem,goods,amount);
        line.setDeliverDate(eta);request.setItems(List.of(line));
        var service=(com.uten.imp.features.purchase.order.PurchaseOrderService)ReflectionTestUtils.getField(fixture,"purchaseOrderService");
        var finance=(com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService)ReflectionTestUtils.getField(fixture,"financeApproval");
        service.createBatch(request);
        UUID item=db.queryForObject("SELECT item.id FROM purchase_order_items item JOIN purchase_order_item_sources source ON source.order_item_id=item.id WHERE source.request_item_id=? AND NOT item.is_deleted",UUID.class,requestItem);
        UUID order=db.queryForObject("SELECT order_id FROM purchase_order_items WHERE id=?",UUID.class,item);
        UUID reviewer=ReflectionTestUtils.invokeMethod(fixture,"createApprover",w);finance.submit("PURCHASE",order);fixture.loginAs(reviewer);
        ReflectionTestUtils.invokeMethod(fixture,"approvePendingFinance","PURCHASE",order);fixture.loginAs(w.superAdminUserId());return item;
    }
    private void receive(FullChainEndToEndTest.World w,UUID orderItem,UUID goods,String qty) {
        ReflectionTestUtils.invokeMethod(fixture,"receiveAndPassPurchase",w,orderItem,goods,new BigDecimal(qty),"root-public-"+orderItem+"-"+qty);
    }
    private record PendingReceipt(UUID receiptId,UUID inspectionId) {}
    private PendingReceipt receiveToInspection(FullChainEndToEndTest.World w,UUID orderItem,UUID goods) {
        fixture.loginAs(w.superAdminUserId());
        var request=new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();
        request.setBillDate(BusinessTime.today());request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture,"purchaseOrderSettlementMethodOf",orderItem));
        var line=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();
        line.setGoodsId(goods);line.setOrderItemId(orderItem);line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("1000"));line.setPrice(new BigDecimal("50"));
        request.setItems(List.of(line));
        var service=(com.uten.imp.features.purchase.receipt.PurchaseReceiptService)ReflectionTestUtils.getField(fixture,"purchaseReceiptService");
        service.create(request);
        UUID receipt=db.queryForObject("SELECT receipt.id FROM purchase_receipts receipt JOIN purchase_receipt_items item ON item.receipt_id=receipt.id WHERE item.order_item_id=? AND NOT receipt.is_deleted AND NOT item.is_deleted",UUID.class,orderItem);
        service.approve(receipt);
        UUID inspection=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='PURCHASE' AND receipt_id=? AND goods_id=?",UUID.class,receipt,goods);
        return new PendingReceipt(receipt,inspection);
    }
    private void passReceipt(FullChainEndToEndTest.World w,PendingReceipt pending) {
        fixture.loginAs(w.superAdminUserId());
        var service=(com.uten.imp.features.warehouse.inbound.ProcurementInspectionService)ReflectionTestUtils.getField(fixture,"inspectionService");
        service.dispose("PURCHASE",pending.receiptId(),pending.inspectionId(),new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                "PASS",null,"公共在途已合格待入库仍可认领","public-pending-pass-"+pending.inspectionId()));
    }
    private void stockReceipt(FullChainEndToEndTest.World w,PendingReceipt pending,String qty) {
        fixture.loginAs(ReflectionTestUtils.invokeMethod(fixture,"createIqcWarehouseConfirmer",w,"public-pending-"+qty+"-"+pending.inspectionId()));
        var service=(com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService)ReflectionTestUtils.getField(fixture,"iqcStockInService");
        com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest request=ReflectionTestUtils.invokeMethod(
                fixture,"latestIqcStockInRequest","PURCHASE",pending.receiptId(),pending.inspectionId(),new BigDecimal(qty),
                "public-pending-stock-"+qty+"-"+pending.inspectionId(),"PUBLIC-A01");
        service.confirm("PURCHASE",pending.receiptId(),request);
    }
    private static MaterialView material(AnalysisView view,UUID goods) { return view.flatMaterials().stream().filter(m->m.goodsId().equals(goods)).findFirst().orElseThrow(); }
    private static void qty(String expected,BigDecimal actual) { assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+", actual "+actual); }
}
