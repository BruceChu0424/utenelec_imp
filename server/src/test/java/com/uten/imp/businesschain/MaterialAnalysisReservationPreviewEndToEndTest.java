package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.production.planning-urge-reconcile.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class MaterialAnalysisReservationPreviewEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    private FullChainEndToEndTest fixture;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    private record Case(FullChainEndToEndTest.World world,UUID analysis,UUID material,UUID first,UUID second,
                        UUID firstMaterial,UUID secondMaterial){}

    @Test void reverseSourceOrderUsesOnePublicBudgetAndPreservesSafety() {
        Case c=create("reverse","120","20");
        var request=issue(c,true,line(c.second(),"80"),line(c.first(),"80"));
        AnalysisView after=assertParity(c,request);
        qty("20",material(after,c.firstMaterial()).allocatedAvailableQty());
        qty("80",material(after,c.secondMaterial()).allocatedAvailableQty());
        qty("100",formal(c));
        qty("20",db.queryForObject("SELECT available_qty FROM v_stock_available WHERE warehouse_id=? AND goods_id=?",
                BigDecimal.class,c.world().warehouseId(),c.material()));
    }

    @Test void draftsKeepPhysicalStockUnreserved() {
        Case c=create("draft","120","20");
        assertParity(c,issue(c,false,line(c.second(),"80"),line(c.first(),"80")));
        qty("0",formal(c));
    }

    @Test void quantityOnlyProjectionCreatesNoReservationOrPlan() {
        Case c=create("typed","120","20");
        AnalysisView view=analyses.detail(c.analysis());
        UUID root=view.products().stream().filter(product->product.analysisLineId().equals(c.first())).findFirst().orElseThrow().rootMaterialLineId();
        // Product rows need not expose the root material identity; use its stable source relation.
        if(root==null) root=db.queryForObject("SELECT root_material_id FROM production_material_analysis_items WHERE id=?",UUID.class,c.first());
        Map<String,Object> before=counts(c);
        readOnlyPreview(c,new PreviewIssuePlansRequest(view.version(),view.fingerprint(),"typed-"+c.analysis(),
                c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(),
                List.of(new PreviewIssuePlansRequest.TypedOutput(root,new BigDecimal("150")))));
        assertEquals(before,counts(c)); qty("0",formal(c));
    }

    @Test void aNewExecutionCommercialSourceInvalidatesTheGuardAndRollsBackTheEntireMutation() {
        Case c=create("source-cas","0","0");
        UUID plan=commands.issueWorkshopPlans(c.analysis(),issue(c,true,line(c.first(),"40"))).plans().getFirst().planId();
        UUID demand=db.queryForObject("SELECT id FROM production_material_demands WHERE plan_id=?",UUID.class,plan);
        var purchase=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        purchase.setBillDate(BusinessTime.today());purchase.setNeedDate(BusinessTime.today().plusDays(5));purchase.setWarehouseId(c.world().warehouseId());
        var line=new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        line.setLineNo(1);line.setGoodsId(c.material());line.setUnitId(c.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("10"));
        purchase.setItems(List.of(line));
        var request=beans.getBean(com.uten.imp.features.purchase.request.PurchaseRequestService.class).create(purchase);
        UUID item=db.queryForObject("SELECT id FROM purchase_request_items WHERE request_id=?",UUID.class,request.getId());
        var transaction=new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class));
        assertThrows(com.uten.imp.application.concurrency.FulfillmentSourceConflictException.class,()->transaction.executeWithoutResult(ignored->{
            beans.getBean(com.uten.imp.security.TxSessionVars.class).bind();
            var footprints=beans.getBean(com.uten.imp.application.port.ProductionMutationFootprintPort.class);
            var guard=beans.getBean(com.uten.imp.application.concurrency.FulfillmentMutationLocks.class)
                    .acquire(()->footprints.forAnalyses(List.of(c.analysis())));
            var entity=beans.getBean(jakarta.persistence.EntityManager.class).find(com.uten.imp.features.production.fulfillment.ProductionMaterialDemand.class,demand);
            var ledger=beans.getBean(com.uten.imp.features.production.fulfillment.ProductionFulfillmentLedgerService.class);
            ledger.createSupplyPeg(entity,"PURCHASE_REQUEST_ITEM",item,new BigDecimal("10"),BusinessTime.today().plusDays(5));
            ledger.refreshDemandStatuses(List.of(demand));
            guard.verifyUnchanged();
        }));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_material_supply_pegs WHERE demand_id=?",Integer.class,demand));
        qty("40",db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE plan_id=?",BigDecimal.class,plan));
        qty("0",formal(c));
    }

    @Test void continuousGrowthPreparesOnlyTheFrozenIncrement() {
        Case c=create("grow-cont","0","0");
        commands.issueWorkshopPlans(c.analysis(),issue(c,true,line(c.first(),"40")));
        db.update("UPDATE stock_balances SET qty=30 WHERE warehouse_id=? AND goods_id=?",c.world().warehouseId(),c.material());
        assertParity(c,issue(c,true,line(c.first(),"40")));
        qty("30",formal(c));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,c.analysis()));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_material_supply_pegs peg JOIN production_material_demands demand ON demand.id=peg.demand_id "
                +"JOIN production_plans plan ON plan.id=demand.plan_id WHERE plan.material_analysis_id=?",Integer.class,c.analysis()),"新分析工单供给仍由preplan负责");
    }

    @Test void fullKitGrowthKeepsItsConfirmedRouteAndWaitsForAllMaterial() {
        Case c=create("grow-full","0","0");
        UUID plan=commands.issueWorkshopPlans(c.analysis(),issue(c,true,line(c.first(),"40"))).plans().getFirst().planId();
        fixture.confirmFullKitRoutes(plan);
        db.update("UPDATE stock_balances SET qty=30 WHERE warehouse_id=? AND goods_id=?",c.world().warehouseId(),c.material());
        assertParity(c,issue(c,true,line(c.first(),"40")));
        qty("0",formal(c));
        assertEquals("FULL_KIT",db.queryForObject("SELECT start_route FROM production_execution_segments WHERE plan_id=?",String.class,plan));
    }

    @Test void historicalMixedPegUsesItsRealReceiptBeforePublicStockWhenGrowingFullKit() {
        Case c=create("mixed-peg","0","0");
        UUID plan=commands.issueWorkshopPlans(c.analysis(),issue(c,true,line(c.first(),"40"))).plans().getFirst().planId();
        fixture.confirmFullKitRoutes(plan);
        UUID demand=db.queryForObject("SELECT id FROM production_material_demands WHERE plan_id=?",UUID.class,plan);
        var request=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        request.setBillDate(BusinessTime.today());request.setNeedDate(BusinessTime.today().plusDays(5));request.setWarehouseId(c.world().warehouseId());
        var material=new com.uten.imp.features.purchase.request.dto.RequestItemLine();
        material.setLineNo(1);material.setGoodsId(c.material());material.setUnitId(c.world().unitId());material.setUnitRate(BigDecimal.ONE);
        material.setQty(new BigDecimal("20"));request.setItems(List.of(material));
        var purchasing=beans.getBean(com.uten.imp.features.purchase.request.PurchaseRequestService.class);
        var created=purchasing.create(request);purchasing.approve(created.getId());
        UUID requestItem=db.queryForObject("SELECT id FROM purchase_request_items WHERE request_id=?",UUID.class,created.getId());
        UUID orderItem=approvePurchase(c,requestItem,"20");
        new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class))
                .executeWithoutResult(ignored->{
                    beans.getBean(com.uten.imp.security.TxSessionVars.class).bind();
                    var entity=beans.getBean(jakarta.persistence.EntityManager.class).find(com.uten.imp.features.production.fulfillment.ProductionMaterialDemand.class,demand);
                    var ledger=beans.getBean(com.uten.imp.features.production.fulfillment.ProductionFulfillmentLedgerService.class);
                    ledger.createSupplyPeg(entity,"PURCHASE_ORDER_ITEM",orderItem,new BigDecimal("20"),BusinessTime.today());
                    ledger.refreshDemandStatuses(List.of(demand));
                });
        ReflectionTestUtils.invokeMethod(fixture,"receiveAndPassPurchase",c.world(),orderItem,c.material(),new BigDecimal("20"),"rp-mixed-receive-"+c.analysis());
        fixture.loginAs(c.world().superAdminUserId());
        qty("0",formal(c)); // Only 20 of the existing full kit of 40 has arrived; its peg remains open.
        // Public opening stock in a new sibling leaf, leaving the receipt's managed
        // quantity/value pool untouched. No guard or source identity is disabled.
        UUID main=UUID.randomUUID(),publicLeaf=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,status) VALUES(?,?,?,'使用')",main,"RP-MAIN-"+main,"预览主仓");
        db.update("UPDATE warehouses SET parent_id=? WHERE id=?",main,c.world().warehouseId());
        db.update("INSERT INTO warehouses(id,code,name,status,parent_id) VALUES(?,?,?,'使用',?)",publicLeaf,"RP-PUBLIC-"+publicLeaf,"预览公共子仓",main);
        db.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES (?,?,60)",publicLeaf,c.material());
        assertParity(c,issue(c,true,line(c.first(),"40")));
        qty("80",formal(c));
        qty("20",db.queryForObject("SELECT SUM(consumed_qty) FROM production_material_supply_pegs WHERE demand_id=?",BigDecimal.class,demand));
        qty("20",db.queryForObject("SELECT SUM(allocated_qty) FROM production_material_receipt_allocations WHERE demand_id=? AND status='EFFECTIVE'",BigDecimal.class,demand));
    }

    @Test void exactQualifiedSourcesStayWithTheirOriginalNodeAboveTheSafetyFloor() {
        Case c=create("exact","0","0");
        receiveOwned(c);
        // A later safety-floor change must not take already qualified, source-owned stock
        // away from its admitted production demand.
        db.update("UPDATE goods SET min_qty=80 WHERE id=?",c.material());
        var request=issue(c,true,line(c.second(),"60"),line(c.first(),"50"));
        AnalysisView after=assertParity(c,request);
        qty("0",material(after,c.secondMaterial()).allocatedAvailableQty());
        qty("100",material(after,c.firstMaterial()).allocatedAvailableQty());
        qty("50",formal(c));
        qty("100",db.queryForObject("SELECT SUM(qty-consumed_qty-released_qty) FROM stock_reservations "
                +"WHERE goods_id=? AND status=0 AND NOT is_deleted",BigDecimal.class,c.material()));
    }

    @Test void fixedBatchChildGrowthChangesCommittedOutputWithoutReservingMaterialAgain() {
        var w=fixture.seedWorld("reservation-preview-fixed-child");fixture.loginAs(w.superAdminUserId());
        UUID root=UUID.randomUUID(),child=UUID.randomUUID(),leaf=UUID.randomUUID();
        fixture.insertGoods(root,"RP-FR-"+root,"固定批次根","自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(child,"RP-FC-"+child,"固定批次子件","自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(leaf,"RP-FL-"+leaf,"固定批次原料","采购",w.unitId(),w.unitLegacy());
        fixture.insertBom(root,child,"1");fixture.insertBom(child,leaf,"10");
        db.update("UPDATE goods_bom_items SET consumption_basis='FIXED_BATCH',basis_output_qty=100,allow_partial_package=FALSE WHERE goods_id=?",child);
        db.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES (?,?,10)",w.warehouseId(),leaf);
        var view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"rp-fixed-"+root,List.of(new PreviewItem("OTHER",null,root,null,
                w.unitId(),"rp-fixed-source-"+root,"固定批次无增量耗用",BusinessTime.today().plusDays(10),new BigDecimal("100")))));
        view=analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"rp-fixed-routes-"+root,
                view.flatMaterials().stream().filter(MaterialView::actionable).map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),
                        row.goodsId().equals(leaf)?"BUY":"MAKE",null)).toList()));
        UUID childMaterial=view.flatMaterials().stream().filter(row->row.goodsId().equals(child)).findFirst().orElseThrow().materialLineId();
        UUID leafMaterial=view.flatMaterials().stream().filter(row->row.goodsId().equals(leaf)).findFirst().orElseThrow().materialLineId();
        Case c=new Case(w,view.analysisId(),leaf,view.products().getFirst().analysisLineId(),null,leafMaterial,null);
        UUID plan=commands.issueWorkshopPlans(c.analysis(),issue(c,true,new IssueWorkshopPlansRequest.IssuePlanLine(childMaterial,null,
                new BigDecimal("40"),null,null,null,null,null,null,null))).plans().getFirst().planId();
        UUID anchor=material(analyses.detail(c.analysis()),childMaterial).planAnchorAnalysisLineId();
        qty("10",formal(c));
        assertParity(c,issue(c,true,line(anchor,"40")));
        qty("10",formal(c));
        qty("80",db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE plan_id=?",BigDecimal.class,plan));
        qty("10",db.queryForObject("SELECT required_qty FROM production_material_demands WHERE plan_id=?",BigDecimal.class,plan));
    }

    private Case create(String label,String stock,String safety) {
        var w=fixture.seedWorld("reservation-preview-"+label);fixture.loginAs(w.superAdminUserId());
        UUID first=UUID.randomUUID(),second=UUID.randomUUID(),material=UUID.randomUUID();
        fixture.insertGoods(first,"RP-A-"+first,"预览产品A","自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(second,"RP-B-"+second,"预览产品B","自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(material,"RP-M-"+material,"预览共用料","采购",w.unitId(),w.unitLegacy());
        fixture.insertBom(first,material,"1");fixture.insertBom(second,material,"1");
        db.update("UPDATE goods SET min_qty=?,default_supplier_id=? WHERE id=?",new BigDecimal(safety),w.supplierId(),material);
        db.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES (?,?,?)",w.warehouseId(),material,new BigDecimal(stock));
        var view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"rp-preview-"+first,List.of(
                new PreviewItem("OTHER",null,first,null,w.unitId(),"rp-a-"+first,"预览来源A",BusinessTime.today().plusDays(10),new BigDecimal("100")),
                new PreviewItem("OTHER",null,second,null,w.unitId(),"rp-b-"+second,"预览来源B",BusinessTime.today().plusDays(10),new BigDecimal("100")))));
        view=analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"rp-route-"+first,
                view.flatMaterials().stream().filter(MaterialView::actionable).map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),
                        row.goodsId().equals(material)?"BUY":"MAKE",null)).toList()));
        UUID a=view.products().stream().filter(row->row.goodsId().equals(first)).findFirst().orElseThrow().analysisLineId();
        UUID b=view.products().stream().filter(row->row.goodsId().equals(second)).findFirst().orElseThrow().analysisLineId();
        UUID ma=view.flatMaterials().stream().filter(row->row.analysisLineId().equals(a)&&row.goodsId().equals(material)).findFirst().orElseThrow().materialLineId();
        UUID mb=view.flatMaterials().stream().filter(row->row.analysisLineId().equals(b)&&row.goodsId().equals(material)).findFirst().orElseThrow().materialLineId();
        return new Case(w,view.analysisId(),material,a,b,ma,mb);
    }

    private AnalysisView assertParity(Case c,IssueWorkshopPlansRequest request) {
        var previewRequest=new PreviewIssuePlansRequest(request.version(),request.fingerprint(),request.idempotencyKey(),request.warehouseId(),
                request.billDate(),request.deliveryDate(),request.approveNow(),request.lines(),List.of());
        Map<String,Object> before=counts(c);
        AnalysisView preview=readOnlyPreview(c,previewRequest);
        AnalysisView replay=readOnlyPreview(c,previewRequest);
        assertEquals(List.of(),MaterialAnalysisPreviewParity.mismatches(preview,replay,Set.of()),"同一预览必须稳定");
        assertEquals(before,counts(c),"预览不得写计划、命令或库存预留");
        AnalysisView after=commands.issueWorkshopPlans(c.analysis(),request).analysis();
        assertEquals(List.of(),MaterialAnalysisPreviewParity.mismatches(preview,after,Set.of()));
        for(MaterialView row:after.flatMaterials()) {
            org.assertj.core.api.Assertions.assertThat(material(preview,row.materialLineId()).warehouseBreakdown())
                    .as("分仓数量与来源必须与真实下达一致；数据库运算的小数位数不改变数量")
                    .usingRecursiveComparison()
                    .withComparatorForType(BigDecimal::compareTo,BigDecimal.class)
                    .isEqualTo(row.warehouseBreakdown());
        }
        return after;
    }

    private AnalysisView readOnlyPreview(Case c,PreviewIssuePlansRequest request) {
        var transaction=new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class));
        transaction.setReadOnly(true);transaction.setIsolationLevel(org.springframework.transaction.TransactionDefinition.ISOLATION_REPEATABLE_READ);
        return transaction.execute(ignored->{db.execute("SET TRANSACTION READ ONLY");return commands.previewIssuePlans(c.analysis(),request);});
    }

    private Map<String,Object> counts(Case c) {return db.queryForMap("""
            SELECT (SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?) plans,
                   (SELECT COUNT(*) FROM production_material_analysis_commands WHERE analysis_id=?) commands,
                   (SELECT COUNT(*) FROM stock_reservations WHERE goods_id=?) reservations,
                   (SELECT COALESCE(SUM(qty-consumed_qty-released_qty),0) FROM stock_reservations WHERE goods_id=? AND status=0 AND NOT is_deleted) reserved
            """,c.analysis(),c.analysis(),c.material(),c.material());}
    private BigDecimal formal(Case c) {return db.queryForObject("SELECT COALESCE(SUM(qty-released_qty),0) FROM stock_reservations "
            +"WHERE goods_id=? AND owner_type='PRODUCTION_MATERIAL_DEMAND' AND NOT is_deleted",BigDecimal.class,c.material());}
    private IssueWorkshopPlansRequest issue(Case c,boolean approve,IssueWorkshopPlansRequest.IssuePlanLine... lines) {
        var view=analyses.detail(c.analysis());return new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"rp-issue-"+UUID.randomUUID(),
                c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),approve,List.of(lines));
    }
    private static IssueWorkshopPlansRequest.IssuePlanLine line(UUID id,String qty){return new IssueWorkshopPlansRequest.IssuePlanLine(id,new BigDecimal(qty));}
    private static MaterialView material(AnalysisView view,UUID id){return view.flatMaterials().stream().filter(row->row.materialLineId().equals(id)).findFirst().orElseThrow();}
    private static void qty(String expected,BigDecimal actual){assertEquals(0,new BigDecimal(expected).compareTo(actual),()->expected+" != "+actual);}

    private void receiveOwned(Case c) {
        var view=analyses.detail(c.analysis());
        commands.notifySupply(c.analysis(),new NotifyRequest(view.version(),view.fingerprint(),"rp-buy-"+c.analysis(),"BUY",List.of(c.firstMaterial()),List.of(),
                List.of(new SupplyQuantityInput(null,c.firstMaterial(),new BigDecimal("100"),BigDecimal.ZERO))));
        UUID requestItem=db.queryForObject("SELECT allocation.external_item_id FROM preplan_supply_actions action JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id "
                +"WHERE action.analysis_id=? AND action.route='BUY'",UUID.class,c.analysis());
        UUID item=approvePurchase(c,requestItem,"100");
        ReflectionTestUtils.invokeMethod(fixture,"receiveAndPassPurchase",c.world(),item,c.material(),new BigDecimal("100"),"rp-receive-"+c.analysis());
        fixture.loginAs(c.world().superAdminUserId());
    }

    private UUID approvePurchase(Case c,UUID requestItem,String quantity) {
        var request=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture,"activeSettlementMethodId"));
        request.setBillDate(BusinessTime.today());request.setSupplierId(c.world().supplierId());request.setCurrencyId(c.world().currencyId());
        request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        com.uten.imp.features.purchase.order.dto.OrderItemLine line=ReflectionTestUtils.invokeMethod(fixture,"ma65OrderLine",c.world(),requestItem,c.material(),quantity);
        line.setDeliverDate(BusinessTime.today().plusDays(5));request.setItems(List.of(line));
        var orders=(com.uten.imp.features.purchase.order.PurchaseOrderService)ReflectionTestUtils.getField(fixture,"purchaseOrderService");
        var finance=(com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService)ReflectionTestUtils.getField(fixture,"financeApproval");
        orders.createBatch(request);
        UUID item=db.queryForObject("SELECT item.id FROM purchase_order_items item JOIN purchase_order_item_sources source ON source.order_item_id=item.id WHERE source.request_item_id=? AND NOT item.is_deleted",UUID.class,requestItem);
        UUID order=db.queryForObject("SELECT order_id FROM purchase_order_items WHERE id=?",UUID.class,item);
        UUID reviewer=ReflectionTestUtils.invokeMethod(fixture,"createApprover",c.world());finance.submit("PURCHASE",order);fixture.loginAs(reviewer);
        ReflectionTestUtils.invokeMethod(fixture,"approvePendingFinance","PURCHASE",order);fixture.loginAs(c.world().superAdminUserId());
        return item;
    }
}
