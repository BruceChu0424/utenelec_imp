package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialStockReallocationService;
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
import java.util.List;
import java.util.Set;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

/** Real purchase -> IQC -> leaf stock -> inverse discovery -> yield -> replenishment. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class PreplanReallocationMainWarehouseEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialStockReallocationService reallocations;
    @Autowired com.uten.imp.features.production.analysis.MaterialAnalysisCommandService commands;
    private FullChainEndToEndTest fixture;
    @BeforeEach void prepare() { fixture = new FullChainEndToEndTest(); beans.autowireBean(fixture); }
    @Test void deficientPlanSelectsLeafStockAndItsNextReceiptPrioritizesDonor() { run(false); }
    @Test void donorCanOrderNewGapAfterYieldAndOwnReceiptClosesPriorityInPlace() { run(true); }

    @Test void issuedWaitingPlansKeepExactEntitlementsAvailableForExplicitReallocation() { run(false,true); }
    private void run(boolean replenishDonor) { run(replenishDonor,false); }
    private void run(boolean replenishDonor, boolean issuedWaiting) {
        var world = fixture.seedWorld("realloc-main-" + replenishDonor + "-" + issuedWaiting);
        fixture.loginAs(world.superAdminUserId());
        UUID main = warehouse(null), second = warehouse(main), other = warehouse(null);
        db.update("UPDATE warehouses SET parent_id=? WHERE id=?", main, world.warehouseId());
        UUID product = UUID.randomUUID(), material = UUID.randomUUID();
        fixture.insertGoods(product,"Y-P-"+product,"调拨产品","自制",world.unitId(),world.unitLegacy());
        fixture.insertGoods(material,"Y-M-"+material,"调拨原料","采购",world.unitId(),world.unitLegacy());
        fixture.insertBom(product,material,"1");
        if(issuedWaiting) {
            UUID missing=UUID.randomUUID();
            fixture.insertGoods(missing,"Y-WAIT-"+missing,"待另一种料","采购",world.unitId(),world.unitLegacy());
            fixture.insertBom(product,missing,"1");
        }
        db.update("UPDATE goods SET default_supplier_id=? WHERE id=?",world.supplierId(),material);
        AnalysisView a = preview(world,main,product,"A","10");
        // This journey keeps exact stock available for explicit reallocation.
        // Choose full-kit before receipts; switching away from continuous after
        // preparation intentionally preserves its already-reserved material.
        if (issuedWaiting) a=issueWaiting(a,main,product,"10");
        UUID purchase = purchase(world,a,material);
        receive(world,purchase,material,"6","A-first");
        receive(at(world,second),purchase,material,"4","A-second");
        fixture.loginAs(world.superAdminUserId());
        a = analyses.detail(a.analysisId());
        AnalysisView b = preview(world,main,product,"B","14");
        if(issuedWaiting) {
            b=issueWaiting(b,main,product,"14");
        }
        MaterialView am = material(a,material), bm = material(b,material);
        var candidates = reallocations.sources(b.analysisId(),bm.materialLineId(),null,1,20);
        assertEquals(1,candidates.getTotal());
        assertEquals(a.analysisId(),candidates.getItems().getFirst().sourceAnalysisId());
        qty("10",candidates.getItems().getFirst().sourceLendableQty());
        qty("14",candidates.getItems().getFirst().shortageQty());
        assertEquals(1,reallocations.candidates(a.analysisId(),am.materialLineId(),null,1,20).getTotal());
        AnalysisView outsider = preview(world,other,product,"other","4");
        assertTrue(reallocations.sources(outsider.analysisId(),material(outsider,material).materialLineId(),null,1,20).getItems().isEmpty());
        final UUID sourceId = a.analysisId();
        var wrong = request(a,am,outsider,material(outsider,material),"wrong-"+sourceId);
        assertThrows(ApiException.class,()->reallocations.create(sourceId,wrong));
        var request = request(a,am,b,bm,"yield-main-"+sourceId);
        AnalysisView updatedTarget = reallocations.createReturningTarget(sourceId,request);
        assertEquals(b.analysisId(),updatedTarget.analysisId());
        qty("4",material(updatedTarget,material).exactPeggedQty());
        reallocations.createReturningTarget(sourceId,request);
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM preplan_material_reallocations WHERE from_analysis_id=?",Integer.class,sourceId));
        AnalysisView yielded = analyses.detail(sourceId);
        qty("4",material(yielded,material).priorityPendingQty());
        qty("4",material(yielded,material).demandSupplyGapQty());
        assertEquals(Set.of(world.warehouseId(),second),Set.copyOf(db.queryForList("""
                SELECT DISTINCT warehouse_id FROM stock_reservations
                WHERE owner_type='PREPLAN_ANALYSIS' AND goods_id=? AND NOT is_deleted
                """,UUID.class,material)));
        qty("10",db.queryForObject("SELECT SUM(qty) FROM stock_balances WHERE goods_id=?",BigDecimal.class,material));
        assertTrue(reallocations.sources(b.analysisId(),bm.materialLineId(),null,1,20).getItems().isEmpty());
        AnalysisView replenishedPlan = analyses.detail(replenishDonor ? sourceId : b.analysisId());
        UUID nextPurchase = purchase(world,replenishedPlan,material);
        receive(at(world,second),nextPurchase,material,replenishDonor ? "4" : "10","next");
        fixture.loginAs(world.superAdminUserId());
        MaterialView finalA = material(analyses.detail(sourceId),material);
        MaterialView finalB = material(analyses.detail(b.analysisId()),material);
        qty("10",finalA.exactPeggedQty()); qty("0",finalA.priorityPendingQty());
        qty("4",finalA.priorityFulfilledQty());
        qty(replenishDonor ? "4" : "10",finalB.exactPeggedQty());
        assertEquals("FULFILLED",db.queryForObject("SELECT status FROM preplan_material_reallocations WHERE from_analysis_id=?",String.class,sourceId));
        qty(replenishDonor ? "14" : "20",db.queryForObject("SELECT SUM(qty) FROM stock_balances WHERE goods_id=?",BigDecimal.class,material));
        qty(replenishDonor ? "14" : "20",db.queryForObject("""
                SELECT SUM(balance.effective_qty) FROM v_preplan_stock_entitlement_beneficiary_balance balance
                JOIN stock_reservations reservation ON reservation.id=balance.stock_reservation_id
                WHERE reservation.goods_id=?
                """,BigDecimal.class,material));
        assertEquals(second,db.queryForObject("""
                SELECT reservation.warehouse_id FROM preplan_stock_entitlement_events event
                JOIN stock_reservations reservation ON reservation.id=event.stock_reservation_id
                WHERE event.beneficiary_analysis_id=? AND event.event_type=?
                """,UUID.class,sourceId,replenishDonor ? "PRIORITY_SATISFIED_IN_PLACE" : "PRIORITY_IN"));
    }
    @Test void donorReplenishmentPreviewAndSevenUnitPurchaseKeepFourPrivateAndThreePublic() {
        var w=fixture.seedWorld("yield-extra-seven");fixture.loginAs(w.superAdminUserId());
        UUID product=UUID.randomUUID(),goods=UUID.randomUUID();
        fixture.insertGoods(product,"Y-X-P-"+product,"让料补供产品","自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(goods,"Y-X-M-"+goods,"让料补供原料","采购",w.unitId(),w.unitLegacy());
        fixture.insertBom(product,goods,"1");db.update("UPDATE goods SET default_supplier_id=? WHERE id=?",w.supplierId(),goods);
        AnalysisView a=preview(w,w.warehouseId(),product,"A","10");
        UUID original=purchase(w,a,goods);receive(w,original,goods,"10","original");fixture.loginAs(w.superAdminUserId());
        a=analyses.detail(a.analysisId());AnalysisView b=preview(w,w.warehouseId(),product,"B","4");
        var transfer=request(a,material(a,goods),b,material(b,goods),"yield-extra-command-"+a.analysisId());
        reallocations.create(a.analysisId(),transfer);
        int actions=db.queryForObject("SELECT COUNT(*) FROM preplan_supply_actions WHERE analysis_id=?",Integer.class,a.analysisId());
        var preview=reallocations.replenishmentPreviewForCommand(a.analysisId(),transfer.idempotencyKey());
        assertEquals(a.analysisId(),preview.sourceAnalysis().analysisId());assertEquals(material(a,goods).materialLineId(),preview.sourceMaterialLineId());
        assertEquals(b.analysisId(),preview.targetAnalysisId());qty("4",preview.defaultQty());qty("4",preview.remainingSupplementQty());
        assertEquals(List.of("BUY"),preview.allowedRoutes());assertTrue(preview.canOverSupply());assertFalse(preview.requiresPreparation());
        assertEquals("NOTIFY_SUPPLY",preview.operation());
        assertEquals(actions,db.queryForObject("SELECT COUNT(*) FROM preplan_supply_actions WHERE analysis_id=?",Integer.class,a.analysisId()));
        final UUID wrongSource=b.analysisId();assertThrows(ApiException.class,()->reallocations.replenishmentPreview(wrongSource,preview.reallocationId()));
        var source=preview.sourceAnalysis();
        var supply=new NotifyRequest(source.version(),source.fingerprint(),"yield-buy-seven-"+a.analysisId(),"BUY",
                List.of(preview.sourceMaterialLineId()),List.of(),List.of(new SupplyQuantityInput(null,preview.sourceMaterialLineId(),
                    // ADR-099 数量单一口径：填总量 7，服务端按还需安排 4 分账(需求 4 + 公共 3)。
                    new BigDecimal("7"),BigDecimal.ZERO)));
        commands.notifySupply(a.analysisId(),supply);commands.notifySupply(a.analysisId(),supply);
        var action=db.queryForMap("SELECT id,requested_qty,public_surplus_qty,external_document_id FROM preplan_supply_actions WHERE analysis_id=? AND route='BUY' ORDER BY generation DESC LIMIT 1",a.analysisId());
        qty("4",(BigDecimal)action.get("requested_qty"));qty("3",(BigDecimal)action.get("public_surplus_qty"));
        qty("4",db.queryForObject("SELECT SUM(allocated_qty) FROM preplan_supply_action_allocations WHERE action_id=?",BigDecimal.class,action.get("id")));
        qty("0",reallocations.replenishmentPreview(a.analysisId(),preview.reallocationId()).remainingSupplementQty());
        qty("4",material(analyses.detail(a.analysisId()),goods).priorityPendingQty());
        approveAndReceiveAllRequestItems(w,(UUID)action.get("external_document_id"),goods);
        fixture.loginAs(w.superAdminUserId());
        qty("10",material(analyses.detail(a.analysisId()),goods).exactPeggedQty());
        qty("4",material(analyses.detail(b.analysisId()),goods).exactPeggedQty());
        qty("17",db.queryForObject("SELECT SUM(qty) FROM stock_balances WHERE goods_id=?",BigDecimal.class,goods));
        qty("3",db.queryForObject("SELECT COALESCE((SELECT SUM(qty) FROM stock_balances WHERE goods_id=?),0)-COALESCE((SELECT SUM(qty-consumed_qty-released_qty) FROM stock_reservations WHERE goods_id=? AND status=0 AND NOT is_deleted),0)",BigDecimal.class,goods,goods));
        qty("0",reallocations.replenishmentPreview(a.analysisId(),preview.reallocationId()).priorityPendingQty());
    }

    private void approveAndReceiveAllRequestItems(FullChainEndToEndTest.World w,UUID requestId,UUID goods) {
        var requestItems=db.queryForList("SELECT id,qty FROM purchase_request_items WHERE request_id=? AND NOT is_deleted ORDER BY id",requestId);
        var order=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        order.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture,"activeSettlementMethodId"));
        order.setBillDate(java.time.LocalDate.of(2026,1,15));order.setSupplierId(w.supplierId());order.setWarehouseId(w.warehouseId());
        order.setCurrencyId(w.currencyId());order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);
        var lines=new java.util.ArrayList<com.uten.imp.features.purchase.order.dto.OrderItemLine>();
        for(var row:requestItems) {
            var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();line.setGoodsId(goods);line.setRequestItemId((UUID)row.get("id"));
            line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty((BigDecimal)row.get("qty"));line.setPrice(new BigDecimal("50"));
            lines.add(line);
        }
        order.setItems(lines);
        var purchases=(com.uten.imp.features.purchase.order.PurchaseOrderService)ReflectionTestUtils.getField(fixture,"purchaseOrderService");
        var finance=(com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService)ReflectionTestUtils.getField(fixture,"financeApproval");
        purchases.createBatch(order);
        var orderIds=db.queryForList("SELECT DISTINCT item.order_id FROM purchase_order_items item JOIN purchase_order_item_sources source ON source.order_item_id=item.id JOIN purchase_request_items request_item ON request_item.id=source.request_item_id WHERE request_item.request_id=?",UUID.class,requestId);
        UUID reviewer=ReflectionTestUtils.invokeMethod(fixture,"createApprover",w);
        for(UUID orderId:orderIds) { fixture.loginAs(w.superAdminUserId());finance.submit("PURCHASE",orderId);fixture.loginAs(reviewer);ReflectionTestUtils.invokeMethod(fixture,"approvePendingFinance","PURCHASE",orderId); }
        fixture.loginAs(w.superAdminUserId());
        for(var row:db.queryForList("SELECT item.id,item.qty FROM purchase_order_items item WHERE item.order_id IN (SELECT DISTINCT item2.order_id FROM purchase_order_items item2 JOIN purchase_order_item_sources source ON source.order_item_id=item2.id JOIN purchase_request_items request_item ON request_item.id=source.request_item_id WHERE request_item.request_id=?) AND NOT item.is_deleted ORDER BY item.id",requestId))
            receive(w,(UUID)row.get("id"),goods,((BigDecimal)row.get("qty")).toPlainString(),"extra");
    }

    private AnalysisView preview(FullChainEndToEndTest.World w,UUID warehouse,UUID product,String label,String qty) {
        fixture.loginAs(w.superAdminUserId());
        return analyses.preview(new PreviewRequest(null,null,null,warehouse,"yield-preview-"+product+label,
                List.of(new PreviewItem("OTHER",null,product,null,w.unitId(),"yield-"+product+label,
                        "跨计划让料验证",BusinessTime.today().plusDays(10),new BigDecimal(qty)))));
    }
    private AnalysisView issueWaiting(AnalysisView view,UUID warehouse,UUID product,String quantity) {
        MaterialView root=material(view,product);
        view=analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),
                "yield-root-"+view.analysisId(),List.of(new RouteDecision(root.materialLineId(),root.actionGroupKey(),"MAKE",null))));
        var result=commands.issueWorkshopPlans(view.analysisId(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),
                "yield-plan-"+view.analysisId(),warehouse,BusinessTime.today(),null,true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(view.products().getFirst().analysisLineId(),new BigDecimal(quantity)))));
        UUID plan=result.plans().getFirst().planId();
        UUID segment=db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=?",UUID.class,plan);
        fixture.confirmFullKitRoute(plan,segment);
        assertEquals("FULL_KIT",db.queryForObject("SELECT start_route FROM production_execution_segments WHERE id=?",String.class,segment));
        assertEquals("WAITING",db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?",String.class,segment));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM plan_draw_links WHERE plan_id=? AND NOT is_deleted",Integer.class,plan));
        qty("0",db.queryForObject("""
                SELECT COALESCE(SUM(reservation.qty-reservation.released_qty),0)
                FROM stock_reservations reservation JOIN production_material_demands demand ON demand.id=reservation.demand_id
                WHERE demand.plan_id=? AND NOT reservation.is_deleted
                """,BigDecimal.class,plan));
        return analyses.detail(view.analysisId());
    }
    private UUID warehouse(UUID parent) {
        UUID id=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,parent_id,status) VALUES(?,?,?,?,'使用')",id,"Y-W-"+id,"让料仓",parent);
        return id;
    }
    private UUID purchase(FullChainEndToEndTest.World world,AnalysisView view,UUID material) {
        fixture.loginAs(world.superAdminUserId());
        MaterialView row=material(view,material);
        AnalysisView routed=analyses.saveRoutes(view.analysisId(),new RouteRequest(
                view.version(),view.fingerprint(),"yield-route-"+view.analysisId()+":"+view.version(),
                List.of(new RouteDecision(row.materialLineId(),row.actionGroupKey(),"BUY",null))));
        commands.notifySupply(view.analysisId(),new NotifyRequest(routed.version(),routed.fingerprint(),
                "yield-notify-"+view.analysisId()+":"+routed.version(),"BUY",List.of(row.materialLineId()),List.of(),null));
        return ReflectionTestUtils.invokeMethod(fixture,"approveExistingAnalysisPurchase",world,view.analysisId(),material);
    }
    private void receive(FullChainEndToEndTest.World world,UUID purchase,UUID material,String qty,String suffix) {
        ReflectionTestUtils.invokeMethod(fixture,"receiveAndPassPurchase",world,purchase,material,new BigDecimal(qty),"yield-"+purchase+suffix);
    }
    private static FullChainEndToEndTest.World at(FullChainEndToEndTest.World w,UUID warehouse) {
        return new FullChainEndToEndTest.World(w.departmentId(),w.employeeId(),w.superAdminUserId(),w.goodsA(),w.goodsB(),w.goodsC(),w.goodsD(),w.goodsE(),w.clientId(),w.supplierId(),warehouse,w.unitId(),w.currencyId(),w.colorId(),w.unitLegacy());
    }
    private static MaterialView material(AnalysisView view,UUID goods) {
        return view.flatMaterials().stream().filter(row->row.goodsId().equals(goods)).findFirst().orElseThrow();
    }
    private static CrossReallocationRequest request(AnalysisView a,MaterialView am,AnalysisView b,MaterialView bm,String key) {
        return new CrossReallocationRequest(a.version(),a.fingerprint(),am.materialLineId(),b.analysisId(),b.version(),b.fingerprint(),bm.materialLineId(),new BigDecimal("4"),"加急计划先调入四套物料",key);
    }
    private static void qty(String expected,BigDecimal actual) {
        assertNotNull(actual); assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+", actual "+actual);
    }
}
