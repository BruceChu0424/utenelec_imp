package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.plan.ProductionPlanService;
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

import static org.junit.jupiter.api.Assertions.*;

/** Real procurement PASS, exact ownership and automatic multi-warehouse DRAW flow. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class QualifiedSourceWarehouseEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionPlanService plans;
    @Autowired com.uten.imp.features.production.mrp.ProductionPlanningPackageService packages;
    @Autowired com.uten.imp.features.stock.StockDocService stockDocuments;
    @Autowired com.uten.imp.features.production.execution.ProductionExecutionSegmentService execution;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactionManager;
    @Autowired com.uten.imp.application.port.ProductionMutationFootprintPort footprints;
    @Autowired com.uten.imp.application.port.PreplanInboundAllocationReadPort inboundAllocations;
    private FullChainEndToEndTest fixture;
    @BeforeEach void prepare(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}

    @Test void qualifiedReceiptsStillCoverDemandWhenPublicSafetyThresholdExceedsTheWholeBatch(){
        for(boolean special:List.of(false,true)){
            var w=fixture.seedWorld("qualified-with-safety-"+special);
            Case c=create(w,"safety");
            db.update("UPDATE goods SET min_qty=20 WHERE id=?",c.material());
            UUID actual=special?warehouse("qualified-safety-special",true):w.warehouseId();
            UUID receipt=receive(c,actual,"10");pass(c,actual,receipt,"10");
            assertEquals("READY",status(c));qty("0",material(c).shortageQty());
            qty("10",db.queryForObject("SELECT sum(r.qty-r.released_qty) FROM stock_reservations r JOIN production_material_demands d ON d.id=r.demand_id WHERE d.plan_id=?",BigDecimal.class,c.plan()));
        }
    }

    @Test void qualifiedSourceAcrossTwoOtherMainWarehousesPromotesOnlyWhenCompleteAndCreatesActualDraws(){
        var w=fixture.seedWorld("qualified-two-warehouses");
        Case c=create(w,"split");UUID b=warehouse("qualified-B",true),d=warehouse("qualified-C",false);
        UUID first=receive(c,b,"5");pass(c,b,first,"5");
        assertEquals("WAITING",status(c));assertEquals(0,drawCount(c));
        var partial=material(c);
        qty("5",partial.shortageQty());
        qty("5",partial.exactPeggedQty());
        UUID second=receive(c,d,"5");pass(c,d,second,"5");
        assertEquals("READY",status(c));assertEquals(2,drawCount(c));
        var complete=material(c);qty("0",complete.shortageQty());qty("0",complete.demandSupplyGapQty());
        var actualAllocations=inboundAllocations.actualForBatches(db.queryForList(
                "SELECT id FROM procurement_iqc_stock_in_batches WHERE receipt_id IN (?,?)",UUID.class,first,second)).stream()
                .filter(allocation->c.analysis().equals(allocation.analysisId())&&allocation.qty().signum()>0).toList();
        qty("10",actualAllocations.stream().map(com.uten.imp.application.port.PreplanInboundAllocationReadPort.AllocationView::qty).reduce(BigDecimal.ZERO,BigDecimal::add));
        assertEquals(java.util.Set.of(b,d),actualAllocations.stream().map(com.uten.imp.application.port.PreplanInboundAllocationReadPort.AllocationView::actualWarehouseId).collect(java.util.stream.Collectors.toSet()));
        assertTrue(actualAllocations.stream().allMatch(allocation->allocation.actualWarehouseId().equals(allocation.targetWarehouseId())));
        for(UUID actual:List.of(b,d)) qty("5",complete.warehouseBreakdown().stream().filter(row->actual.equals(row.warehouseId())).map(WarehouseBreakdown::onHandQty).reduce(BigDecimal.ZERO,BigDecimal::add));
        QualifiedOriginWarehouseAssertions.verify(db,transactionManager,footprints,c.packageId(),w.warehouseId(),List.of(b,d));
        for(UUID actual:List.of(b,d)){
            qty("5",db.queryForObject("SELECT sum(item.base_qty) FROM production_planning_package_document_items link JOIN stock_document_items item ON item.id=link.document_item_id JOIN stock_documents doc ON doc.id=item.doc_id WHERE link.package_id=? AND link.document_type='DRAW' AND doc.warehouse_id=?",BigDecimal.class,c.packageId(),actual));
            qty("5",db.queryForObject("SELECT sum(qty) FROM stock_reservations WHERE owner_type='PRODUCTION_MATERIAL_DEMAND' AND demand_id IN (SELECT id FROM production_material_demands WHERE execution_segment_id=?) AND warehouse_id=? AND requires_qualified_origin",BigDecimal.class,c.segment(),actual));
        }
        assertEquals(0,db.queryForObject("""
                SELECT count(*) FROM preplan_stock_entitlement_events event
                JOIN stock_reservations source ON source.id=event.stock_reservation_id
                JOIN stock_reservations target ON target.id=event.target_stock_reservation_id
                WHERE event.target_package_id=? AND event.event_type='FORMALIZE'
                  AND (source.warehouse_id<>target.warehouse_id OR NOT fn_preplan_reservation_has_qualified_origin(source.id))
                """,Integer.class,c.packageId()));
        assertEquals(w.warehouseId(),db.queryForObject("SELECT warehouse_id FROM production_planning_packages WHERE id=?",UUID.class,c.packageId()));
    }

    @Test void publicUninspectedAndOtherAnalysisStockCannotFillTheQualifiedSourceShortage(){
        var w=fixture.seedWorld("qualified-boundaries");
        Case c=create(w,"primary");UUID b=warehouse("qualified-isolated",true);
        // This is a real unrelated OTHER_IN, not a fabricated balance or a PASS event.
        call("putDirectTargetStock",withWarehouse(w,b),c.material(),"100");
        UUID first=receive(c,b,"5");pass(c,b,first,"5");
        assertEquals("WAITING",status(c));assertEquals(0,drawCount(c));
        Case other=create(w,"other-analysis");
        UUID otherReceipt=receive(other,b,"10");pass(other,b,otherReceipt,"10");
        assertEquals("READY",status(other));assertEquals("WAITING",status(c));
        UUID uninspected=receive(c,b,"5");
        assertEquals("WAITING",status(c));assertEquals(0,drawCount(c));
        qty("5",db.queryForObject("SELECT sum(effective_qty) FROM v_preplan_stock_entitlement_beneficiary_balance WHERE beneficiary_analysis_id=?",BigDecimal.class,c.analysis()));
        pass(c,b,uninspected,"5");
        assertEquals("READY",status(c));
        qty("10",db.queryForObject("SELECT sum(qty) FROM stock_reservations WHERE owner_type='PRODUCTION_MATERIAL_DEMAND' AND demand_id IN (SELECT id FROM production_material_demands WHERE execution_segment_id=?)",BigDecimal.class,c.segment()));
        qty("120",db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",BigDecimal.class,b,c.material()));
    }

    @Test void cancellingUnusedPackageRestoresEachQualifiedLotInItsActualWarehouse(){
        var w=fixture.seedWorld("qualified-reverse");Case c=create(w,"reverse");
        UUID b=warehouse("restore-B",true),d=warehouse("restore-C",false);
        pass(c,b,receive(c,b,"4"),"4");pass(c,d,receive(c,d,"6"),"6");
        assertEquals("READY",status(c));
        fixture.loginAs(w.superAdminUserId());
        assertTrue(assertThrows(ApiException.class,()->plans.reverse(c.plan())).getMessage().contains("有效的领料单"));
        var cancellation=new com.uten.imp.features.production.mrp.PlanningPackageLifecycleRequest(
                "qualified-cancel-"+c.plan(),"未领料取消，精确归还实际来源仓");
        assertEquals("CANCELLED",packages.cancel(c.plan(),c.packageId(),cancellation).status());
        assertTrue(packages.cancel(c.plan(),c.packageId(),cancellation).replayed());
        assertEquals(0,db.queryForObject("""
                SELECT count(*) FROM stock_reservations target
                WHERE target.demand_id IN(SELECT id FROM production_material_demands WHERE execution_segment_id=?)
                  AND target.qty-target.released_qty>0 AND target.requires_qualified_origin
                """,Integer.class,c.segment()));
        for(var expected:List.of(new Object[]{b,"4"},new Object[]{d,"6"})){
            qty((String)expected[1],db.queryForObject("""
                    SELECT sum(balance.effective_qty) FROM v_preplan_stock_entitlement_beneficiary_balance balance
                    JOIN stock_reservations source ON source.id=balance.stock_reservation_id
                    WHERE balance.beneficiary_analysis_id=? AND source.warehouse_id=?
                    """,BigDecimal.class,c.analysis(),expected[0]));
            qty((String)expected[1],db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",BigDecimal.class,expected[0],c.material()));
        }
    }

    @Test void directMakeQualifiedInboundFollowsItsActualWarehouseButSubcontractPreparationIsNotFinalSupply(){
        MakeCase c=makeCase("qualified-direct-make",false);
        UUID actual=warehouse("actual-qualified-MAKE",true);
        call("produceInternal",withWarehouse(c.world(),actual),c.childPlanItem(),c.childGoods(),"1");
        assertEquals("READY",segmentStatus(c.parentPlan()));
        qty("1",db.queryForObject("""
                SELECT sum(exact.qty) FROM preplan_analysis_stock_exact_pegs exact
                JOIN stock_reservations source ON source.id=exact.stock_reservation_id
                WHERE exact.make_source_analysis_item_id=? AND exact.supply_action_allocation_id IS NULL
                  AND source.warehouse_id=? AND fn_preplan_reservation_has_qualified_origin(source.id)
                """,BigDecimal.class,c.childAnalysisItem(),actual));
        qty("1",db.queryForObject("""
                SELECT sum(target.qty) FROM stock_reservations target
                JOIN production_material_demands demand ON demand.id=target.demand_id
                WHERE demand.plan_id=? AND target.warehouse_id=? AND target.requires_qualified_origin
                """,BigDecimal.class,c.parentPlan(),actual));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND route='MAKE'",Integer.class,c.analysis()));

        MakeCase sc=makeCase("qualified-sc-not-final",true);
        call("produceInternal",sc.world(),sc.leafPlanItem(),sc.leafGoods(),"1");
        assertEquals("READY",segmentStatus(sc.childPlan()));
        for(UUID draw:db.queryForList("SELECT draw_id FROM plan_draw_links WHERE plan_id=? AND NOT is_deleted",UUID.class,sc.childPlan())){
            com.uten.imp.features.stock.dto.StockDocIssueRequest request=call("drawIssueRequest",draw,
                    "qualified-sc-draw-"+draw,null,BigDecimal.ZERO);
            stockDocuments.approveAndIssue(draw,request);
        }
        call("produceInternal",sc.world(),sc.childPlanItem(),sc.childGoods(),"1");
        assertEquals("WAITING",segmentStatus(sc.parentPlan()));
        qty("1",db.queryForObject("""
                SELECT sum(qty-consumed_qty-released_qty) FROM stock_reservations
                WHERE owner_type='SUBCONTRACT_PREPARE_TASK' AND goods_id=? AND warehouse_id=?
                  AND status=0 AND NOT is_deleted
                """,BigDecimal.class,sc.childGoods(),sc.world().warehouseId()));
        assertEquals(0,db.queryForObject("""
                SELECT count(*) FROM preplan_stock_entitlement_events event
                JOIN stock_reservations source ON source.id=event.stock_reservation_id
                WHERE event.event_type='ORIGIN_MAKE' AND source.goods_id=?
                """,Integer.class,sc.childGoods()));
        var waiting=execution.list(sc.parentPlan()).getFirst();
        assertTrue(assertThrows(ApiException.class,()->execution.recheckMaterial(sc.parentPlan(),waiting.id(),
                new com.uten.imp.features.production.execution.SegmentTransitionRequest(waiting.lockVersion(),"qualified-sc-not-final-"+waiting.id())))
                .getMessage().contains("仍缺料"));
        assertEquals("WAITING",segmentStatus(sc.parentPlan()));
    }

    private MakeCase makeCase(String tag,boolean subcontract){
        var w=fixture.seedWorld(tag);fixture.loginAs(w.superAdminUserId());
        UUID parent=UUID.randomUUID(),child=UUID.randomUUID(),leaf=subcontract?UUID.randomUUID():null;
        fixture.insertGoods(parent,"MAKE-P-"+parent,"父件原需求","自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(child,"MAKE-C-"+child,"原树子件",subcontract?"委外":"自制",w.unitId(),w.unitLegacy());
        fixture.insertBom(parent,child,"1");
        if(subcontract){fixture.insertGoods(leaf,"MAKE-L-"+leaf,"前置底层子件","自制",w.unitId(),w.unitLegacy());fixture.insertBom(child,leaf,"1");}
        var view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"make-preview-"+parent,
                List.of(new PreviewItem("OTHER",null,parent,null,w.unitId(),"make-source-"+parent,"原树实际自制来源",BusinessTime.today().plusDays(10),BigDecimal.ONE))));
        view=analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"make-routes-"+parent,
                view.flatMaterials().stream().map(m->new RouteDecision(m.materialLineId(),m.actionGroupKey(),subcontract&&m.goodsId().equals(child)?"SUBCONTRACT":"MAKE",null)).toList()));
        UUID parentAnalysis=view.products().getFirst().analysisLineId();
        List<IssueWorkshopPlansRequest.IssuePlanLine> lines=new java.util.ArrayList<>();
        if(subcontract){UUID leafId=leaf;UUID material=view.flatMaterials().stream().filter(m->m.goodsId().equals(leafId)).map(MaterialView::materialLineId).findFirst().orElseThrow();
            lines.add(new IssueWorkshopPlansRequest.IssuePlanLine(material,null,BigDecimal.ONE,null,null,null,null,null,null,null));}
        UUID childMaterial=view.flatMaterials().stream().filter(m->m.goodsId().equals(child)).map(MaterialView::materialLineId).findFirst().orElseThrow();
        lines.add(new IssueWorkshopPlansRequest.IssuePlanLine(childMaterial,null,BigDecimal.ONE,null,null,null,null,null,null,null));
        lines.add(new IssueWorkshopPlansRequest.IssuePlanLine(parentAnalysis,BigDecimal.ONE));
        commands.issueWorkshopPlans(view.analysisId(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"make-issue-"+parent,
                w.warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,lines));
        UUID parentPlan=db.queryForObject("SELECT id FROM production_plans WHERE material_analysis_item_id=?",UUID.class,parentAnalysis);
        UUID childAnchor=db.queryForObject("SELECT id FROM production_material_analysis_items WHERE analysis_id=? AND parent_analysis_material_id=? AND NOT is_deleted",UUID.class,view.analysisId(),childMaterial);
        UUID childPlan=db.queryForObject("SELECT id FROM production_plans WHERE material_analysis_item_id=?",UUID.class,childAnchor);
        UUID childItem=db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=? AND goods_id=?",UUID.class,childPlan,child);
        UUID leafItem=subcontract?db.queryForObject("SELECT pi.id FROM production_plan_items pi JOIN production_plans p ON p.id=pi.plan_id WHERE p.material_analysis_id=? AND pi.goods_id=?",UUID.class,view.analysisId(),leaf):null;
        assertEquals("WAITING",segmentStatus(parentPlan));
        return new MakeCase(w,view.analysisId(),parentPlan,childPlan,childItem,childAnchor,child,leafItem,leaf);
    }

    private String segmentStatus(UUID plan){return db.queryForObject("SELECT status FROM production_execution_segments WHERE plan_id=?",String.class,plan);}

    private Case create(FullChainEndToEndTest.World w,String suffix){
        fixture.loginAs(w.superAdminUserId());UUID product=UUID.randomUUID();
        fixture.insertGoods(product,"QUAL-"+product,"按原需求跨仓领料","自制",w.unitId(),w.unitLegacy());
        fixture.insertBom(product,w.goodsD(),"1");
        var view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"qualified-preview-"+product,
                List.of(new PreviewItem("OTHER",null,product,null,w.unitId(),"qualified-"+product,"实际来源资格验证",BusinessTime.today().plusDays(10),BigDecimal.TEN))));
        view=analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"qualified-routes-"+product,
                view.flatMaterials().stream().map(m->new RouteDecision(m.materialLineId(),m.actionGroupKey(),m.goodsId().equals(product)?"MAKE":"BUY",null)).toList()));
        UUID materialLine=view.flatMaterials().stream().filter(m->m.goodsId().equals(w.goodsD())).map(MaterialView::materialLineId).findFirst().orElseThrow();
        commands.notifySupply(view.analysisId(),new NotifyRequest(view.version(),view.fingerprint(),"qualified-notify-"+product,"BUY",List.of(materialLine),null,null));
        view=analyses.detail(view.analysisId());UUID root=view.products().getFirst().analysisLineId();
        var issued=commands.issueWorkshopPlans(view.analysisId(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),
                "qualified-issue-"+product,w.warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(root,BigDecimal.TEN))));
        UUID plan=issued.plans().getFirst().planId();UUID analysis=view.analysisId();
        UUID orderItem=call("approveExistingAnalysisPurchase",w,analysis,w.goodsD());
        UUID segment=db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=?",UUID.class,plan);
        UUID packageId=db.queryForObject("SELECT package_id FROM production_execution_segments WHERE id=?",UUID.class,segment);
        Case result=new Case(w,analysis,plan,segment,packageId,w.goodsD(),orderItem);
        assertEquals("WAITING",status(result));return result;
    }

    private UUID receive(Case c,UUID warehouse,String qty){
        fixture.loginAs(c.world().superAdminUserId());
        return call("receiveIntoQuarantine",withWarehouse(c.world(),warehouse),c.material(),c.orderItem(),qty);
    }
    private void pass(Case c,UUID warehouse,UUID receipt,String qty){call("passAndStockPurchase",withWarehouse(c.world(),warehouse),receipt,qty);}
    private UUID warehouse(String name,boolean defective){
        UUID id=UUID.randomUUID();db.update("INSERT INTO warehouses(id,code,name,status,is_accountable,is_defective) VALUES(?,?,?,'使用',TRUE,?)",id,"WH-"+id,name,defective);return id;
    }
    private String status(Case c){return db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?",String.class,c.segment());}
    private MaterialView material(Case c){return analyses.detail(c.analysis()).flatMaterials().stream().filter(row->row.goodsId().equals(c.material())).findFirst().orElseThrow();}
    private int drawCount(Case c){return db.queryForObject("SELECT count(DISTINCT doc.id) FROM production_planning_package_documents link JOIN stock_documents doc ON doc.id=link.document_id WHERE link.execution_segment_id=? AND link.document_type='DRAW' AND NOT doc.is_deleted",Integer.class,c.segment());}
    private static FullChainEndToEndTest.World withWarehouse(FullChainEndToEndTest.World w,UUID warehouse){
        return new FullChainEndToEndTest.World(w.departmentId(),w.employeeId(),w.superAdminUserId(),w.goodsA(),w.goodsB(),w.goodsC(),w.goodsD(),w.goodsE(),w.clientId(),w.supplierId(),warehouse,w.unitId(),w.currencyId(),w.colorId(),w.unitLegacy());
    }
    /** Reuse fixture procedures which still execute the actual business services and database guards. */
    private <T>T call(String method,Object...args){return ReflectionTestUtils.invokeMethod(fixture,method,args);}
    private static void qty(String expected,BigDecimal actual){assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual),()->"Expected quantity "+expected+", actual "+actual);}
    private record Case(FullChainEndToEndTest.World world,UUID analysis,UUID plan,UUID segment,UUID packageId,UUID material,UUID orderItem){}
    private record MakeCase(FullChainEndToEndTest.World world,UUID analysis,UUID parentPlan,UUID childPlan,UUID childPlanItem,
                            UUID childAnalysisItem,UUID childGoods,UUID leafPlanItem,UUID leafGoods){}
}
