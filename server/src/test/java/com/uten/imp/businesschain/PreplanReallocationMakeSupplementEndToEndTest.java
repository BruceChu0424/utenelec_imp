package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialStockReallocationService;
import com.uten.imp.features.production.execution.ProductionDrawRequest;
import com.uten.imp.features.production.execution.ProductionDrawRequestService;
import com.uten.imp.features.production.execution.ProductionExecutionSegmentService;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
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
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;

/** Actual child manufacture and origin inventory, followed by explicit donor replenishment. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class PreplanReallocationMakeSupplementEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired MaterialStockReallocationService reallocations;
    @Autowired ProductionDrawRequestService draws;
    @Autowired ProductionExecutionSegmentService segments;
    @Autowired StockDocService stock;
    @Autowired com.uten.imp.features.stock.allocation.ProductionMaterialSettlementService settlements;
    @Autowired com.uten.imp.features.subcontract.order.SubcontractOrderService subcontractOrders;
    @Autowired com.uten.imp.features.subcontract.receipt.SubcontractReceiptService subcontractReceipts;
    @Autowired com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService subcontractIssues;
    @Autowired com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService finance;
    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementInspectionService inspection;
    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService iqc;
    FullChainEndToEndTest fixture;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void logout(){org.springframework.security.core.context.SecurityContextHolder.clearContext();}

    @Test void completedMakeChildCanReplaceFourYieldedUnitsWithoutChangingTheOriginalTenUnitHistory() {
        var c=scenario("make-supplement",true);
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",c.world(),c.raw(),"10");
        AnalysisView a=preview(c,"A","10");
        UUID materialId=material(a,c.child()).materialLineId();
        var first=commands.issueWorkshopPlans(a.analysisId(),planRequest(c,a,materialId,"10","make-first-"+a.analysisId())).plans().getFirst();
        UUID childItem=db.queryForObject("SELECT material_analysis_item_id FROM production_plans WHERE id=?",UUID.class,first.planId());
        finish(c,first,"10");
        assertTrue(db.queryForObject("SELECT bool_and(status='COMPLETED') FROM production_execution_segments WHERE plan_id=?",Boolean.class,first.planId()));
        assertTrue(db.queryForObject("SELECT EXISTS(SELECT 1 FROM preplan_stock_entitlement_events event JOIN stock_reservations reservation ON reservation.id=event.stock_reservation_id WHERE event.event_type='ORIGIN_MAKE' AND event.beneficiary_analysis_id=? AND reservation.goods_id=?)",Boolean.class,a.analysisId(),c.child()));
        a=analyses.detail(a.analysisId());
        qty("10",material(a,c.child()).exactPeggedQty());
        String original=planHistory(first.planId());
        AnalysisView b=preview(c,"B","4");
        yieldFour(c,a,b);
        AnalysisView yielded=analyses.detail(a.analysisId());
        MaterialView donor=material(yielded,c.child());
        assertEquals(materialId,donor.materialLineId());qty("10",donor.requiredQty());qty("4",donor.priorityPendingQty());qty("4",donor.demandSupplyGapQty());
        qty("10",db.queryForObject("SELECT requested_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,childItem));
        var request=planRequest(c,yielded,materialId,"4","make-supplement-"+a.analysisId());
        var supplemented=commands.issueWorkshopPlans(a.analysisId(),request);
        UUID nextPlan=supplemented.plans().getFirst().planId();
        assertEquals(childItem,db.queryForObject("SELECT material_analysis_item_id FROM production_plans WHERE id=?",UUID.class,nextPlan));
        qty("14",db.queryForObject("SELECT requested_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,childItem));
        assertEquals(nextPlan,commands.issueWorkshopPlans(a.analysisId(),request).plans().getFirst().planId());
        analyses.detail(a.analysisId());analyses.detail(a.analysisId());
        qty("14",db.queryForObject("SELECT requested_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,childItem));
        assertEquals(original,planHistory(first.planId()));
        qty("10",material(analyses.detail(a.analysisId()),c.child()).requiredQty());
        replenishRaw(c,a.analysisId(),nextPlan);
        finish(c,supplemented.plans().getFirst(),"4");
        var finalA=material(analyses.detail(a.analysisId()),c.child());var finalB=material(analyses.detail(b.analysisId()),c.child());
        qty("10",finalA.exactPeggedQty());qty("0",finalA.priorityPendingQty());qty("4",finalA.priorityFulfilledQty());qty("4",finalB.exactPeggedQty());
        qty("14",db.queryForObject("SELECT sum(event.qty) FROM preplan_stock_entitlement_events event JOIN stock_reservations reservation ON reservation.id=event.stock_reservation_id WHERE event.event_type='ORIGIN_MAKE' AND event.beneficiary_analysis_id=? AND reservation.goods_id=?",BigDecimal.class,a.analysisId(),c.child()));
        qty("14",db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE goods_id=?",BigDecimal.class,c.child()));
        assertEquals("FULFILLED",db.queryForObject("SELECT status FROM preplan_material_reallocations WHERE from_analysis_id=?",String.class,a.analysisId()));
        assertEquals(original,planHistory(first.planId()));
    }

    @Test void completedLeafSubcontractSupplyCanReplaceFourYieldedQualifiedUnitsThroughANewApplication() {
        var c=scenario("subcontract-leaf-supplement",false);
        AnalysisView a=preview(c,"A","10");
        UUID materialId=material(a,c.child()).materialLineId();
        notifySubcontract(a,materialId,"subcontract-first-"+a.analysisId());
        UUID firstApplication=latestSubcontractApplicationItem(a.analysisId(),c.child());
        completeSubcontract(c,firstApplication,"10");
        a=analyses.detail(a.analysisId());
        qty("10",material(a,c.child()).exactPeggedQty());
        assertTrue(db.queryForObject("SELECT EXISTS(SELECT 1 FROM preplan_stock_entitlement_events event JOIN stock_reservations reservation ON reservation.id=event.stock_reservation_id WHERE event.event_type='ORIGIN_IQC' AND event.beneficiary_analysis_id=? AND reservation.goods_id=?)",Boolean.class,a.analysisId(),c.child()));
        AnalysisView b=preview(c,"B","4");yieldFour(c,a,b);
        var yielded=analyses.detail(a.analysisId());qty("4",material(yielded,c.child()).demandSupplyGapQty());
        notifySubcontract(yielded,materialId,"subcontract-supplement-"+a.analysisId());
        UUID nextApplication=latestSubcontractApplicationItem(a.analysisId(),c.child());assertNotEquals(firstApplication,nextApplication);
        qty("4",db.queryForObject("SELECT qty FROM subcontract_application_items WHERE id=?",BigDecimal.class,nextApplication));
        qty("10",db.queryForObject("SELECT qty FROM subcontract_application_items WHERE id=?",BigDecimal.class,firstApplication));
        completeSubcontract(c,nextApplication,"4");
        var finalA=material(analyses.detail(a.analysisId()),c.child());qty("10",finalA.requiredQty());qty("10",finalA.exactPeggedQty());
        qty("0",finalA.priorityPendingQty());qty("4",finalA.priorityFulfilledQty());
        qty("4",material(analyses.detail(b.analysisId()),c.child()).exactPeggedQty());
        assertEquals("FULFILLED",db.queryForObject("SELECT status FROM preplan_material_reallocations WHERE from_analysis_id=?",String.class,a.analysisId()));
    }

    @Test void alreadyArrangedMakeOutputRemainsPublicWhenBorrowersEarlierPurchaseFirstRestoresTheDonor() {
        var c=scenario("make-extra-after-priority",true);
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",c.world(),c.raw(),"10");
        AnalysisView a=preview(c,"A","10");UUID materialId=material(a,c.child()).materialLineId();
        var originalPlan=commands.issueWorkshopPlans(a.analysisId(),planRequest(c,a,materialId,"10","make-initial-"+a.analysisId())).plans().getFirst();
        finish(c,originalPlan,"10");a=analyses.detail(a.analysisId());
        String originalHistory=planHistory(originalPlan.planId());

        AnalysisView b=preview(c,"B","4");MaterialView borrowerMaterial=material(b,c.child());
        b=analyses.saveRoutes(b.analysisId(),new RouteRequest(b.version(),b.fingerprint(),"borrower-buy-route-"+b.analysisId(),
                List.of(new RouteDecision(borrowerMaterial.materialLineId(),borrowerMaterial.actionGroupKey(),"BUY",null))));
        commands.notifySupply(b.analysisId(),new NotifyRequest(b.version(),b.fingerprint(),"borrower-buy-first-"+b.analysisId(),"BUY",List.of(borrowerMaterial.materialLineId()),List.of(),null));
        UUID borrowerPurchase=ReflectionTestUtils.invokeMethod(fixture,"approveExistingAnalysisPurchase",c.world(),b.analysisId(),c.child());
        qty("4",db.queryForObject("SELECT qty FROM purchase_order_items WHERE id=?",BigDecimal.class,borrowerPurchase));

        fixture.loginAs(c.world().superAdminUserId());yieldFour(c,analyses.detail(a.analysisId()),analyses.detail(b.analysisId()));
        var yielded=analyses.detail(a.analysisId());qty("4",material(yielded,c.child()).priorityPendingQty());
        var makeRequest=planRequest(c,yielded,materialId,"4","make-already-arranged-"+a.analysisId());
        var supplementary=commands.issueWorkshopPlans(a.analysisId(),makeRequest).plans().getFirst();
        UUID child=db.queryForObject("SELECT material_analysis_item_id FROM production_plans WHERE id=?",UUID.class,supplementary.planId());
        qty("14",db.queryForObject("SELECT requested_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,child));
        replenishRaw(c,a.analysisId(),supplementary.planId());

        ReflectionTestUtils.invokeMethod(fixture,"receiveAndPassPurchase",c.world(),borrowerPurchase,c.child(),new BigDecimal("4"),"borrower-priority-stock-"+borrowerPurchase);
        fixture.loginAs(c.world().superAdminUserId());
        var restoredA=material(analyses.detail(a.analysisId()),c.child());
        qty("10",restoredA.exactPeggedQty());qty("0",restoredA.priorityPendingQty());qty("4",restoredA.priorityFulfilledQty());
        qty("4",material(analyses.detail(b.analysisId()),c.child()).exactPeggedQty());
        assertEquals("FULFILLED",db.queryForObject("SELECT status FROM preplan_material_reallocations WHERE from_analysis_id=?",String.class,a.analysisId()));

        finish(c,supplementary,"4");
        var finalA=material(analyses.detail(a.analysisId()),c.child());
        qty("10",finalA.requiredQty());qty("10",finalA.exactPeggedQty());qty("0",finalA.priorityPendingQty());
        qty("4",material(analyses.detail(b.analysisId()),c.child()).exactPeggedQty());
        qty("18",db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE goods_id=?",BigDecimal.class,c.child()));
        qty("4",ReflectionTestUtils.invokeMethod(fixture,"publicAvailable",c.world().warehouseId(),c.child()));
        qty("10",db.queryForObject("SELECT sum(event.qty) FROM preplan_stock_entitlement_events event JOIN stock_reservations reservation ON reservation.id=event.stock_reservation_id WHERE event.event_type='ORIGIN_MAKE' AND event.beneficiary_analysis_id=? AND reservation.goods_id=?",BigDecimal.class,a.analysisId(),c.child()));
        assertEquals(originalHistory,planHistory(originalPlan.planId()));
        assertEquals(supplementary.planId(),commands.issueWorkshopPlans(a.analysisId(),makeRequest).plans().getFirst().planId());
        qty("14",db.queryForObject("SELECT requested_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,child));
        qty("4",ReflectionTestUtils.invokeMethod(fixture,"publicAvailable",c.world().warehouseId(),c.child()));
    }

    @Test void completedSubcontractPreparationCanManufactureAndNotifyOnlyFourReplacementUnitsAfterYield() {
        var c=scenario("subcontract-make-supplement",false);fixture.insertBom(c.child(),c.raw(),"1");
        // V581 起「只有一个叶子子件」的委外件走 COMPONENT_OUTBOUND 委外下达，issue-plans
        // 拒收；本用例测「让料后补 4 件」的前置自制链，挂第二颗采购叶子让它保留车间路线
        //（同 MaterialWorkshopAnchorEndToEndTest#createMixed 的做法，路线映射里补 BUY）。
        fixture.insertBom(c.child(),c.world().goodsD(),"1");
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",c.world(),c.raw(),"10");
        AnalysisView a=preview(c,"A","10");UUID materialId=material(a,c.child()).materialLineId();
        var first=commands.issueWorkshopPlans(a.analysisId(),planRequest(c,a,materialId,"10","submake-first-"+a.analysisId())).plans().getFirst();
        UUID childItem=db.queryForObject("SELECT material_analysis_item_id FROM production_plans WHERE id=?",UUID.class,first.planId());
        finish(c,first,"10");
        UUID originalApplication=latestSubcontractApplicationItem(a.analysisId(),c.child());
        completeSubcontract(c,originalApplication,"10");a=analyses.detail(a.analysisId());
        qty("10",material(a,c.child()).exactPeggedQty());String history=planHistory(first.planId());
        AnalysisView b=preview(c,"B","4");yieldFour(c,a,b);
        var yielded=analyses.detail(a.analysisId());qty("4",material(yielded,c.child()).demandSupplyGapQty());
        var next=commands.issueWorkshopPlans(a.analysisId(),planRequest(c,yielded,materialId,"4","submake-supplement-"+a.analysisId())).plans().getFirst();
        assertEquals(childItem,db.queryForObject("SELECT material_analysis_item_id FROM production_plans WHERE id=?",UUID.class,next.planId()));
        qty("14",db.queryForObject("SELECT requested_qty FROM production_material_analysis_items WHERE id=?",BigDecimal.class,childItem));
        var task=db.queryForMap("SELECT required_qty,produced_qty,notified_qty FROM preplan_subcontract_make_tasks WHERE preparation_item_id=? AND status='ACTIVE'",childItem);
        qty("14",(BigDecimal)task.get("required_qty"));qty("10",(BigDecimal)task.get("produced_qty"));qty("10",(BigDecimal)task.get("notified_qty"));
        replenishRaw(c,a.analysisId(),next.planId());
        finish(c,next,"4");
        UUID replacement=latestSubcontractApplicationItem(a.analysisId(),c.child());assertNotEquals(originalApplication,replacement);
        qty("4",db.queryForObject("SELECT qty FROM subcontract_application_items WHERE id=?",BigDecimal.class,replacement));
        completeSubcontract(c,replacement,"4");
        var finalA=material(analyses.detail(a.analysisId()),c.child());qty("10",finalA.requiredQty());qty("10",finalA.exactPeggedQty());
        qty("0",finalA.priorityPendingQty());qty("4",finalA.priorityFulfilledQty());
        qty("4",material(analyses.detail(b.analysisId()),c.child()).exactPeggedQty());
        assertEquals(history,planHistory(first.planId()));
        qty("14",db.queryForObject("SELECT notified_qty FROM preplan_subcontract_make_tasks WHERE preparation_item_id=? AND status='ACTIVE'",BigDecimal.class,childItem));
    }

    private Scenario scenario(String tag,boolean make) {
        var w=fixture.seedWorld(tag);fixture.loginAs(w.superAdminUserId());
        UUID root=UUID.randomUUID(),child=UUID.randomUUID(),raw=UUID.randomUUID(),workshop=UUID.randomUUID(),worker=UUID.randomUUID();
        fixture.insertGoods(root,"Y-ROOT-"+root,"让料原父产品","自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(child,"Y-CHILD-"+child,"让料可补子件",make?"自制":"委外",w.unitId(),w.unitLegacy());
        fixture.insertGoods(raw,"Y-RAW-"+raw,"子件实际原材料","采购",w.unitId(),w.unitLegacy());
        fixture.insertBom(root,child,"1");if(make)fixture.insertBom(child,raw,"1");
        db.update("UPDATE goods SET default_supplier_id=? WHERE id IN (?,?)",w.supplierId(),child,raw);
        UUID production=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD'",UUID.class);
        db.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES(?,?,?,?,'二级班组')",workshop,"Y-WORK-"+workshop,"让料补供车间",production);
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')",worker,"Y-EMP-"+worker,"补供负责人",workshop);
        return new Scenario(w,root,child,raw,workshop,worker,make);
    }
    private AnalysisView preview(Scenario c,String suffix,String quantity) {
        fixture.loginAs(c.world().superAdminUserId());
        var view=analyses.preview(new PreviewRequest(null,null,null,c.world().warehouseId(),"yield-preview-"+c.root()+suffix,
                List.of(new PreviewItem("OTHER",null,c.root(),null,c.world().unitId(),"yield-"+c.root()+suffix,"让料后的正式补供",BusinessTime.today().plusDays(10),new BigDecimal(quantity)))));
        return analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"yield-routes-"+view.analysisId(),
                view.flatMaterials().stream().filter(MaterialView::actionable).map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),
                        row.goodsId().equals(c.raw())||row.goodsId().equals(c.world().goodsD())?"BUY":row.goodsId().equals(c.child())&&!c.make()?"SUBCONTRACT":"MAKE",null)).toList()));
    }
    private IssueWorkshopPlansRequest planRequest(Scenario c,AnalysisView view,UUID material,String quantity,String key) {
        return new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),key,c.world().warehouseId(),BusinessTime.today(),null,true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(material,null,new BigDecimal(quantity),BusinessTime.today(),null,c.workshop(),null,c.worker(),null,null)));
    }
    private void finish(Scenario c,GeneratedPlan plan,String quantity) {
        fixture.loginAs(c.world().superAdminUserId());
        UUID segment=plan.segmentIds().getFirst();
        List<UUID> documentIds=db.queryForList("SELECT document_id FROM production_planning_package_documents WHERE execution_segment_id=? AND document_type='DRAW' ORDER BY document_id",UUID.class,segment);
        if(!documentIds.isEmpty()) {
            var items=List.of(new ProductionDrawRequest.Item(segment,version(segment)));var preview=draws.preview(new ProductionDrawRequest.PreviewRequest(items));
            draws.submit(new ProductionDrawRequest.SubmitRequest(items,"yield-draw-"+segment,preview.fingerprint()));
            var issue=new StockDocIssueBatchRequest();issue.setIdempotencyKey("yield-issue-"+segment);issue.setDocIds(documentIds);stock.issueFullBatch(issue);
        }
        segments.start(plan.planId(),segment,new SegmentTransitionRequest(version(segment),"yield-start-"+segment));
        var usage=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest();
        usage.setExecutionSegmentId(segment);usage.setIdempotencyKey("yield-material-used-"+segment);usage.setReason("本批实际用料全部用于该批合格产出");
        usage.setLines(db.queryForList("SELECT id,required_qty FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted",segment).stream().map(demand->{
            var line=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line();line.setDemandId((UUID)demand.get("id"));line.setQtyBase((BigDecimal)demand.get("required_qty"));line.setSettlementType("CONSUMED");return line;
        }).toList());
        if(!usage.getLines().isEmpty())settlements.post(plan.planId(),usage,c.world().superAdminUserId());
        UUID planItem=db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,segment);
        UUID report=fixture.reportAndApproveExecutionSegment(c.world(),planItem,null,c.child(),segment,null,quantity,false,"0",null,null);
        fixture.confirmFinishedInboundFully(fixture.finishedInDocForReport(report));
    }
    private void replenishRaw(Scenario c,UUID analysis,UUID nextPlan) {
        assertEquals("WAITING",db.queryForObject("SELECT status FROM production_execution_segments WHERE plan_id=?",String.class,nextPlan));
        var rawView=analyses.detail(analysis);
        var rawCandidates=rawView.flatMaterials().stream().filter(row->row.goodsId().equals(c.raw())&&row.actionable()).toList();
        assertEquals(1,rawCandidates.size(),"补做原材料必须保留一个可操作采购来源，不重复展开；原材料投影="+rawView.flatMaterials().stream().filter(row->row.goodsId().equals(c.raw())).toList());
        var rawMaterial=rawCandidates.getFirst();qty("4",rawMaterial.demandSupplyGapQty());
        rawView=analyses.saveRoutes(analysis,new RouteRequest(rawView.version(),rawView.fingerprint(),"yield-raw-route-"+nextPlan,
                List.of(new RouteDecision(rawMaterial.materialLineId(),rawMaterial.actionGroupKey(),"BUY",null))));
        commands.notifySupply(analysis,new NotifyRequest(rawView.version(),rawView.fingerprint(),"yield-raw-supply-"+nextPlan,"BUY",List.of(rawMaterial.materialLineId()),List.of(),null));
        UUID purchase=ReflectionTestUtils.invokeMethod(fixture,"approveExistingAnalysisPurchase",c.world(),analysis,c.raw());
        qty("4",db.queryForObject("SELECT qty FROM purchase_order_items WHERE id=?",BigDecimal.class,purchase));
        ReflectionTestUtils.invokeMethod(fixture,"receiveAndPassPurchase",c.world(),purchase,c.raw(),new BigDecimal("4"),"yield-raw-stock-"+nextPlan);
        fixture.loginAs(c.world().superAdminUserId());
    }
    private void yieldFour(Scenario c,AnalysisView source,AnalysisView target) {
        fixture.loginAs(c.world().superAdminUserId());source=analyses.detail(source.analysisId());target=analyses.detail(target.analysisId());
        var request=new CrossReallocationRequest(source.version(),source.fingerprint(),material(source,c.child()).materialLineId(),target.analysisId(),target.version(),target.fingerprint(),
                material(target,c.child()).materialLineId(),new BigDecimal("4"),"优先支援急单后补回原计划","yield-four-"+source.analysisId());
        reallocations.createReturningTarget(source.analysisId(),request);
    }
    private void notifySubcontract(AnalysisView view,UUID material,String key) {
        commands.notifySupply(view.analysisId(),new NotifyRequest(view.version(),view.fingerprint(),key,"SUBCONTRACT",List.of(material),List.of(),null));
    }
    private UUID latestSubcontractApplicationItem(UUID analysis,UUID goods) {
        return db.queryForObject("""
                SELECT item.id FROM preplan_supply_actions action JOIN subcontract_application_items item ON item.application_id=action.external_document_id
                WHERE action.analysis_id=? AND action.external_document_type='SUBCONTRACT_APPLICATION' AND item.goods_id=? AND NOT item.is_deleted
                ORDER BY action.generation DESC,action.id DESC LIMIT 1
                """,UUID.class,analysis,goods);
    }
    private void completeSubcontract(Scenario c,UUID applicationItem,String quantity) {
        var w=c.world();fixture.loginAs(w.superAdminUserId());BigDecimal amount=new BigDecimal(quantity);
        if(db.queryForObject("SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted",Integer.class,c.child())==0) {
            // A leaf subcontract is external processing of an existing target
            // blank. Receive its real public input only after the supply request;
            // the order must issue this blank before the supplier can return it.
            ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,c.child(),quantity);
        }
        var order=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        order.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture,"activeSettlementMethodId"));
        order.setBillDate(BusinessTime.today());order.setSupplierId(w.supplierId());order.setWarehouseId(w.warehouseId());order.setCurrencyId(w.currencyId());order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);
        var orderLine=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();orderLine.setGoodsId(c.child());orderLine.setApplicationItemId(applicationItem);orderLine.setUnitId(w.unitId());orderLine.setUnitRate(BigDecimal.ONE);orderLine.setQty(amount);orderLine.setPrice(new BigDecimal("30"));orderLine.setAmountOriginal(amount.multiply(new BigDecimal("30")));orderLine.setAmountLocal(orderLine.getAmountOriginal());order.setItems(List.of(orderLine));
        UUID orderId=subcontractOrders.create(order).getId();UUID orderItem=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",UUID.class,orderId);
        UUID approver=ReflectionTestUtils.invokeMethod(fixture,"createApprover",w);finance.submit("SUBCONTRACT",orderId);fixture.loginAs(approver);ReflectionTestUtils.invokeMethod(fixture,"approvePendingFinance","SUBCONTRACT",orderId);fixture.loginAs(w.superAdminUserId());
        for(UUID issueId:db.queryForList("SELECT DISTINCT issue.id FROM subcontract_material_issues issue JOIN subcontract_material_issue_items item ON item.issue_id=issue.id WHERE item.order_item_id=? AND issue.status=0 AND NOT issue.is_deleted",UUID.class,orderItem)) {
            var detail=subcontractIssues.detail(issueId);var issue=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest();
            issue.setBillDate(detail.getBillDate());issue.setSupplierId(detail.getSupplierId());issue.setWarehouseId(w.warehouseId());issue.setWorkerId(detail.getWorkerId());issue.setDeliverDate(detail.getDeliverDate());
            issue.setItems(detail.getItems().stream().map(original->{var line=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine();line.setLineNo(original.getLineNo());line.setGoodsId(original.getGoodsId());line.setColorId(original.getColorId());line.setUnitId(original.getUnitId());line.setUnitRate(original.getUnitRate());line.setQty(original.getQty());line.setOrderItemId(original.getOrderItemId());line.setPlanItemId(original.getPlanItemId());line.setParentGoodsId(original.getParentGoodsId());line.setParentColorId(original.getParentColorId());return line;}).toList());
            subcontractIssues.update(issueId,issue);subcontractIssues.approve(issueId);
        }
        var receipt=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();receipt.setBillDate(BusinessTime.today());receipt.setSupplierId(w.supplierId());receipt.setWarehouseId(w.warehouseId());receipt.setCurrencyId(w.currencyId());receipt.setExchangeRate(BigDecimal.ONE);receipt.setTaxRate(BigDecimal.ZERO);receipt.setSettlementMethodId(order.getSettlementMethodId());
        var receiptLine=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();receiptLine.setOrderItemId(orderItem);receiptLine.setGoodsId(c.child());receiptLine.setUnitId(w.unitId());receiptLine.setUnitRate(BigDecimal.ONE);receiptLine.setQty(amount);receiptLine.setPrice(new BigDecimal("30"));receiptLine.setAmountOriginal(amount.multiply(new BigDecimal("30")));receiptLine.setAmountLocal(receiptLine.getAmountOriginal());receipt.setItems(List.of(receiptLine));
        UUID receiptId=subcontractReceipts.create(receipt).getId();subcontractReceipts.approve(receiptId);
        UUID inspectionId=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='SUBCONTRACT' AND receipt_id=?",UUID.class,receiptId);
        inspection.dispose("SUBCONTRACT",receiptId,inspectionId,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest("PASS",null,"让料补供委外合格","yield-iqc-"+receiptId));
        fixture.loginAs(ReflectionTestUtils.invokeMethod(fixture,"createIqcWarehouseConfirmer",w,"yield-subcontract-"+receiptId));
        com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest confirmation=ReflectionTestUtils.invokeMethod(fixture,"latestIqcStockInRequest","SUBCONTRACT",receiptId,inspectionId,amount,"yield-iqc-stock-"+receiptId,"SUB-YIELD");
        iqc.confirm("SUBCONTRACT",receiptId,confirmation);fixture.loginAs(w.superAdminUserId());
    }
    private String planHistory(UUID plan) {
        return db.queryForObject("SELECT jsonb_build_array((SELECT jsonb_agg(to_jsonb(item) ORDER BY item.id) FROM production_plan_items item WHERE item.plan_id=?),(SELECT jsonb_agg(to_jsonb(segment) ORDER BY segment.id) FROM production_execution_segments segment WHERE segment.plan_id=?))::text",String.class,plan,plan);
    }
    private long version(UUID segment){return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);}
    private static MaterialView material(AnalysisView view,UUID goods){return view.flatMaterials().stream().filter(row->row.goodsId().equals(goods)&&row.level()==1).findFirst().orElseThrow();}
    private static void qty(String expected,BigDecimal actual){assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+", actual "+actual);}
    private record Scenario(FullChainEndToEndTest.World world,UUID root,UUID child,UUID raw,UUID workshop,UUID worker,boolean make) {}
}
