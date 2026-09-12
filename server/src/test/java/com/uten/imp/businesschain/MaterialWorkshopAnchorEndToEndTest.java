package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.production.plan.ProductionPlanService;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Real node-to-anchor projection and source-quota protection for workshop batch commands.
 *
 * <p>2026-09-10（C05 F1-flow）追加：混合候选一次下达、二次下达复用锚点、两线程不同候选行、
 * 超量行整批回滚——覆盖 batchChildLineIds 的 IN 批量映射与 refresh 收敛后的不变量。
 *
 * <p><b>CI 必须显式设置 {@code UTEN_RUN_DB_TESTS=true}</b>：本类（与 FullChain/Scale 同款门控）
 * 未设置时全部 SKIP，surefire 仍 exit 0，会出现「全绿但没跑」的假象（09-09 的 min(uuid)
 * 回归正是这样漏到运行态的）。
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class MaterialWorkshopAnchorEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionPlanService plans;
    @Autowired com.uten.imp.features.sales.order.SalesOrderService sales;
    @Autowired com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService finance;
    @Autowired com.uten.imp.features.common.taskclaim.TaskClaimService claims;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactionManager;
    @Autowired com.uten.imp.features.stock.StockDocService stockDocuments;
    @Autowired com.uten.imp.features.master.goods.GoodsBomService goodsBom;
    private FullChainEndToEndTest fixture;
    @BeforeEach void prepare(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}

    @Test void unchangedRefreshPreservesBomRowsButStillRecomputesCurrentStockAndVersion() {
        Case c = create("incremental-snapshot", false);
        AnalysisView before = analyses.detail(c.analysis());
        Map<UUID, String> originalRows = materialRowVersions(c);

        AnalysisView unchanged = refreshCase(c, "unchanged");

        assertEquals(before.version() + 1, unchanged.version());
        assertEquals(originalRows, materialRowVersions(c), "Unchanged BOM nodes must not toggle active or reset allocation");
        postGenericStock(c, c.world().goodsC(), "4000", "OTHER_IN");
        fixture.loginAs(c.planner());
        AnalysisView changed = refreshCase(c, "new-stock");
        qty("4000", material(changed, c.materials().getFirst()).allocatedAvailableQty());
        qty("6000", material(changed, c.materials().getFirst()).demandSupplyGapQty());
        assertNotEquals(originalRows.get(c.materials().getFirst()), materialRowVersions(c).get(c.materials().getFirst()));
        Map<UUID, String> updatedRows = materialRowVersions(c);
        refreshCase(c, "stable-stock");
        assertEquals(updatedRows, materialRowVersions(c), "Existing nonzero allocation must remain untouched when its inputs did not change");
    }

    @Test void removingABomEdgeOnlyDeactivatesThatHistoricalNode() {
        Case c = create("incremental-bom-delete", false);
        Map<UUID, String> before = materialRowVersions(c);
        UUID removedMaterial = c.materials().getFirst();
        UUID edge = db.queryForObject("SELECT id FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND is_deleted=FALSE",
                UUID.class, c.root(), c.world().goodsC());
        fixture.loginAs(c.world().superAdminUserId());
        goodsBom.delete(c.root(), edge);
        fixture.loginAs(c.planner());

        AnalysisView refreshed = refreshCase(c, "removed-edge");

        assertFalse(db.queryForObject("SELECT active FROM production_material_analysis_materials WHERE id=?", Boolean.class, removedMaterial));
        assertTrue(refreshed.flatMaterials().stream().noneMatch(row -> row.materialLineId().equals(removedMaterial)));
        var after = materialRowVersions(c);
        for (var row : before.entrySet()) if (!row.getKey().equals(removedMaterial)) assertEquals(row.getValue(), after.get(row.getKey()));
    }

    private Map<UUID, String> materialRowVersions(Case c) {
        Map<UUID, String> result = new LinkedHashMap<>();
        db.query("SELECT id,xmin::text FROM production_material_analysis_materials WHERE analysis_id=? AND node_role='BOM_COMPONENT' ORDER BY id",
                rs -> { result.put(rs.getObject(1, UUID.class), rs.getString(2)); }, c.analysis());
        return result;
    }

    private AnalysisView refreshCase(Case c, String key) {
        AnalysisView view = analyses.detail(c.analysis());
        ProductView source = view.products().stream().filter(row -> row.sourceType().equals("OTHER")).findFirst().orElseThrow();
        return analyses.preview(new PreviewRequest(c.analysis(), view.version(), view.fingerprint(), c.world().warehouseId(),
                key + "-" + c.analysis(), List.of(new PreviewItem("OTHER", null, c.root(), null, c.world().unitId(),
                c.sourceRef(), source.sourceReason(), source.deliveryDate(), source.requestedQty()))));
    }

    @Test void genericStockIncreaseReducesNewChildQuotaWithoutARefreshOnPageEntry() {
        Case c = create("anchor-live-stock-in", false);
        AnalysisView stale = analyses.detail(c.analysis());
        postGenericStock(c, c.world().goodsC(), "4000", "OTHER_IN");
        fixture.loginAs(c.planner());
        assertEquals(stale.version(), analyses.detail(c.analysis()).version(), "Generic stock posting does not silently rewrite the analysis");

        var result = commands.issueWorkshopPlans(c.analysis(), request(c, stale, c.materials().getFirst(), "6000", "live-stock", true));

        UUID anchor = material(result.analysis(), c.materials().getFirst()).planAnchorAnalysisLineId();
        qty("6000", product(result.analysis(), anchor).requestedQty());
        assertQuotaAndPlans(c, anchor, "6000", 1);
    }

    @Test void genericStockCoveringTheWholeCandidateRejectsStaleIssueWithoutCreatingAnAnchor() {
        Case c = create("anchor-stock-covered", false);
        AnalysisView stale = analyses.detail(c.analysis());
        postGenericStock(c, c.world().goodsC(), "10000", "OTHER_IN");
        fixture.loginAs(c.planner());

        ApiException rejected = assertThrows(ApiException.class, () -> commands.issueWorkshopPlans(
                c.analysis(), request(c, stale, c.materials().getFirst(), "10000", "covered", true)));

        assertTrue(rejected.getMessage().contains("刷新"));
        assertEquals(0, count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?", c.analysis()));
        assertEquals(0, count("SELECT count(*) FROM production_material_analysis_items WHERE analysis_id=? AND source_type='MAKE_COMPONENT'", c.analysis()));
    }

    @Test void genericStockDecreaseMakesTheRootWaitAndReplayDoesNotCreateDraws() {
        Case c = create("anchor-live-stock-out", false);
        postGenericStock(c, c.world().goodsC(), "10000", "OTHER_IN");
        postGenericStock(c, c.world().goodsD(), "10000", "OTHER_IN");
        fixture.loginAs(c.planner());
        AnalysisView before = analyses.detail(c.analysis());
        AnalysisView ready = analyses.preview(new PreviewRequest(c.analysis(), before.version(), before.fingerprint(),
                c.world().warehouseId(), "stock-ready-" + c.analysis(), List.of(new PreviewItem("OTHER", null,
                c.root(), null, c.world().unitId(), c.sourceRef(), "实际入库后刷新", BusinessTime.today().plusDays(10), new BigDecimal("10000")))));
        qty("10000", ready.products().getFirst().readyFinishQty());
        postGenericStock(c, c.world().goodsD(), "10000", "OTHER_OUT");
        fixture.loginAs(c.planner());
        var request = new IssueWorkshopPlansRequest(ready.version(), ready.fingerprint(), "stock-out-" + c.analysis(),
                c.world().warehouseId(), BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(ready.products().getFirst().analysisLineId(), new BigDecimal("10000"))));

        var result = commands.issueWorkshopPlans(c.analysis(), request);
        var replay = commands.issueWorkshopPlans(c.analysis(), request);

        UUID plan = result.plans().getFirst().planId();
        assertEquals(plan, replay.plans().getFirst().planId());
        assertEquals(1, count("SELECT count(*) FROM production_execution_segments WHERE plan_id=? AND status='WAITING'", plan));
        assertEquals(0, count("SELECT count(*) FROM production_planning_package_documents doc "
                + "JOIN production_planning_packages package ON package.id=doc.package_id "
                + "JOIN stock_documents stock ON stock.id=doc.document_id "
                + "WHERE package.plan_id=? AND doc.document_type='DRAW' AND stock.is_deleted=FALSE", plan));
    }

    @Test void stockCoverageUsesActualSiblingLeafAndExcludesAnotherMainWarehouse() {
        Case c = create("anchor-leaf-coverage", false);
        UUID leaf = UUID.randomUUID();
        UUID unrelated = UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,parent_id,is_accountable) VALUES (?,?,?, ?,TRUE)",
                leaf, "LEAF-" + leaf, "实际入库分仓", c.world().warehouseId());
        db.update("INSERT INTO warehouses(id,code,name,is_accountable) VALUES (?,?,?,TRUE)",
                unrelated, "OTHER-" + unrelated, "其它主仓库存");
        postGenericStock(c, c.world().goodsC(), "4000", "OTHER_IN", leaf);
        postGenericStock(c, c.world().goodsC(), "10000", "OTHER_IN", unrelated);
        fixture.loginAs(c.planner());
        AnalysisView stale = analyses.detail(c.analysis());

        var result = commands.issueWorkshopPlans(c.analysis(), request(c, stale,
                c.materials().getFirst(), "6000", "leaf-current", true));

        UUID anchor = material(result.analysis(), c.materials().getFirst()).planAnchorAnalysisLineId();
        qty("6000", product(result.analysis(), anchor).requestedQty());
        qty("4000", db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",
                BigDecimal.class, leaf, c.world().goodsC()));
        qty("10000", db.queryForObject("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",
                BigDecimal.class, unrelated, c.world().goodsC()));
    }

    @Test void twoParentPathsKeepTheirPartialFormalCoverageOnTheirOwnOriginalNodes() {
        Case c = create("anchor-formal-paths", true);
        postGenericStock(c, c.world().goodsC(), "6000", "OTHER_IN");
        fixture.loginAs(c.planner());
        var parents = analyses.detail(c.analysis()).flatMaterials().stream()
                .filter(row -> row.level() == 1 && "MAKE".equals(row.sourceConfirmed()))
                .map(MaterialView::materialLineId).toList();
        assertEquals(2, parents.size());
        for (UUID parent : parents) issue(c, parent, "3000", "partial-" + parent, true);

        var view = analyses.detail(c.analysis());
        for (UUID materialId : c.materials()) {
            qty("3000", material(view, materialId).allocatedAvailableQty());
            qty("7000", material(view, materialId).demandSupplyGapQty());
        }
        qty("6000", c.materials().stream().map(id -> material(view, id).allocatedAvailableQty())
                .reduce(BigDecimal.ZERO, BigDecimal::add));
        assertEquals(2, count("SELECT count(*) FROM production_material_demands demand JOIN production_plans plan ON plan.id=demand.plan_id "
                + "WHERE plan.material_analysis_id=? AND demand.required_qty=3000 AND demand.is_deleted=FALSE", c.analysis()));
    }

    private void postGenericStock(Case c, UUID goods, String quantity, String type) {
        postGenericStock(c, goods, quantity, type, c.world().warehouseId());
    }

    private void postGenericStock(Case c, UUID goods, String quantity, String type, UUID warehouse) {
        fixture.loginAs(c.world().superAdminUserId());
        var request = new com.uten.imp.features.stock.dto.StockDocSaveRequest();
        request.setDocType(type); request.setWarehouseId(warehouse); request.setBillDate(BusinessTime.today());
        var item = new com.uten.imp.features.stock.dto.StockDocItemLine();
        item.setGoodsId(goods); item.setUnitId(c.world().unitId()); item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal(quantity)); item.setPrice(BigDecimal.TEN);
        item.setAmountOriginal(item.getQty().multiply(item.getPrice())); item.setAmountLocal(item.getAmountOriginal());
        request.setItems(List.of(item)); stockDocuments.approve(stockDocuments.create(request).getId());
    }

    @Test void repeatedMaterialLineReusesQuotaAnd6000Then4000AreTwoDeltasNotCumulativeTotals(){
        Case c=create("anchor-partial",false);
        UUID material=c.materials().getFirst();
        issue(c,material,"6000","first",true);
        AnalysisView first=analyses.detail(c.analysis());UUID anchor=material(first,material).planAnchorAnalysisLineId();
        assertNotNull(anchor);assertEquals("MAKE_COMPONENT",product(first,anchor).sourceType());
        qty("10000",product(first,anchor).requestedQty());qty("6000",product(first,anchor).approvedQty());
        qty("4000",product(first,anchor).remainingQty());qty("10000",material(first,material).requiredQty());
        assertNull(material(first,material).delegatedToAnalysisLineId());
        assertEquals("ACTIVE",material(first,material).requirementState());
        assertEquals(0,count("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND route='MAKE'",c.analysis()));

        assertThrows(ApiException.class,()->issue(c,material,"10000","wrong-cumulative",true));
        assertQuotaAndPlans(c,anchor,"10000",1);
        AnalysisView current=analyses.detail(c.analysis());
        var request=request(c,current,material,"4000","second",true);
        var second=commands.issueWorkshopPlans(c.analysis(),request);
        var replay=commands.issueWorkshopPlans(c.analysis(),request);
        assertTrue(replay.replayed());assertEquals(second.plans().getFirst().planId(),replay.plans().getFirst().planId());
        assertQuotaAndPlans(c,anchor,"10000",2);
        qty("0",product(analyses.detail(c.analysis()),anchor).remainingQty());
        assertThrows(ApiException.class,()->issue(c,material,"1","new-key-after-full",true));
        assertQuotaAndPlans(c,anchor,"10000",2);
    }

    @Test void equalGoodsOnTwoBomPathsHaveDistinctAnchorsAndLegacyActionIsNotCountedTwice(){
        Case c=create("anchor-paths",true);UUID first=c.materials().get(0),second=c.materials().get(1);
        issue(c,first,"6000","legacy-first",true);
        UUID legacyAnchor=material(analyses.detail(c.analysis()),first).planAnchorAnalysisLineId();
        addHistoricalMakeAction(c,first,legacyAnchor);
        issue(c,first,"4000","legacy-remaining",true);
        issue(c,second,"4000","other-path",true);
        AnalysisView view=analyses.detail(c.analysis());UUID secondAnchor=material(view,second).planAnchorAnalysisLineId();
        assertNotNull(legacyAnchor);assertNotNull(secondAnchor);assertNotEquals(legacyAnchor,secondAnchor);
        qty("10000",product(view,legacyAnchor).requestedQty());qty("0",product(view,legacyAnchor).remainingQty());
        qty("10000",product(view,secondAnchor).requestedQty());qty("6000",product(view,secondAnchor).remainingQty());
        assertEquals(1,count("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND route='MAKE'",c.analysis()));
        assertThrows(ApiException.class,()->issue(c,first,"1","cannot-use-sibling-quota",true));
        assertEquals(3,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
        qty("10000",product(analyses.detail(c.analysis()),legacyAnchor).requestedQty());
    }

    @Test void deletingDraftReleasesItsPlanQuantityWithoutIncreasingTheAnchorDemand(){
        Case c=create("anchor-draft-delete",false);UUID material=c.materials().getFirst();
        var first=issue(c,material,"6000","draft",false);
        UUID anchor=material(first.analysis(),material).planAnchorAnalysisLineId();
        qty("6000",product(first.analysis(),anchor).submittedQty());
        plans.delete(first.plans().getFirst().planId());
        var released=analyses.detail(c.analysis());
        qty("10000",product(released,anchor).requestedQty());qty("10000",product(released,anchor).remainingQty());
        issue(c,material,"4000","after-delete",false);
        qty("10000",product(analyses.detail(c.analysis()),anchor).requestedQty());
        qty("4000",product(analyses.detail(c.analysis()),anchor).submittedQty());
        assertEquals(1,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=? AND NOT is_deleted",c.analysis()));
    }

    @Test void explicitSourceIncreaseAddsOnlyTheNewQuotaAndNeverChangesExistingPlanQuantities(){
        Case c=create("anchor-source-growth",false);UUID material=c.materials().getFirst();
        var first=issue(c,material,"10000","original-demand",true);
        UUID anchor=material(first.analysis(),material).planAnchorAnalysisLineId();
        AnalysisView before=analyses.detail(c.analysis());
        var request=new PreviewRequest(c.analysis(),before.version(),before.fingerprint(),c.world().warehouseId(),
                "grow-source-"+c.analysis(),List.of(new PreviewItem("OTHER",null,c.root(),null,c.world().unitId(),
                        c.sourceRef(),"明确增加原始生产需求",BusinessTime.today().plusDays(10),new BigDecimal("15000"))));
        AnalysisView grown=analyses.preview(request);
        assertEquals(anchor,material(grown,material).planAnchorAnalysisLineId());
        qty("15000",product(grown,anchor).requestedQty());qty("10000",product(grown,anchor).approvedQty());
        qty("5000",product(grown,anchor).remainingQty());
        assertEquals(0,new BigDecimal("10000").compareTo(db.queryForObject(
                "SELECT sum(qty) FROM production_plan_items WHERE plan_id=?",BigDecimal.class,first.plans().getFirst().planId())));
        qty("15000",product(analyses.preview(request),anchor).requestedQty());
        qty("15000",product(analyses.detail(c.analysis()),anchor).requestedQty());
        issue(c,material,"5000","new-source-delta",true);
        assertQuotaAndPlans(c,anchor,"15000",2);
        assertThrows(ApiException.class,()->issue(c,material,"1","source-growth-full",true));
    }

    @Test void approvedRoot6000CanAdmitOnlyFinanceApprovedExtra2000WithoutRewritingOldPackages(){
        Case c=create("anchor-sales-growth",false,true,"6000");
        UUID material=c.materials().getFirst();
        var childPlan=issue(c,material,"6000","child-original",true);
        UUID anchor=material(childPlan.analysis(),material).planAnchorAnalysisLineId();
        AnalysisView view=analyses.detail(c.analysis());
        UUID root=view.products().stream().filter(p->p.salesOrderItemId()!=null)
                .map(ProductView::analysisLineId).findFirst().orElseThrow();
        var rootPlan=issueProduct(c,root,"6000","root-original");
        Map<String,String> oldPlans=frozenPlans(c.analysis());
        qty("6000",product(rootPlan.analysis(),root).approvedQty());

        fixture.loginAs(c.salesActor());
        var changed=new com.uten.imp.features.sales.order.dto.OrderChangeQtyRequest.Line();
        changed.setOrderItemId(c.salesItem());changed.setNewQty(new BigDecimal("8000"));
        var amendment=new com.uten.imp.features.sales.order.dto.OrderChangeQtyRequest();
        amendment.setItems(List.of(changed));sales.changeQty(c.salesOrder(),amendment);
        fixture.loginAs(c.planner());
        ApiException pending=assertThrows(ApiException.class,()->analyses.preview(salesPreview(c,"8000","pending-finance")));
        assertTrue(pending.getMessage().contains("等待财务确认"));
        qty("6000",product(analyses.detail(c.analysis()),root).requestedQty());
        assertEquals(oldPlans,frozenPlans(c.analysis()));

        confirmSales(c.salesOrder(),c.financeActor());fixture.loginAs(c.planner());
        Map<String,String> before=nonPlanningFacts(c);
        ApiException excessive=assertThrows(ApiException.class,()->analyses.preview(salesPreview(c,"9000","over-capacity")));
        assertTrue(excessive.getMessage().contains("超过销售订单尚未安排"));
        UUID otherWarehouse=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,status) VALUES(?,?,?,'使用')",otherWarehouse,"ALT-"+otherWarehouse,"增额不可顺便切换的仓库");
        var latest=analyses.detail(c.analysis());
        var wrongWarehouse=new PreviewRequest(c.analysis(),latest.version(),latest.fingerprint(),otherWarehouse,
                "growth-other-warehouse-"+c.analysis(),salesPreview(c,"8000","warehouse-template").items());
        assertTrue(assertThrows(ApiException.class,()->analyses.preview(wrongWarehouse)).getMessage().contains("不能同时更改"));
        var admitted=analyses.preview(salesPreview(c,"8000","admit-finance-growth"));
        qty("8000",product(admitted,root).requestedQty());qty("2000",product(admitted,root).remainingQty());
        qty("8000",product(admitted,anchor).requestedQty());qty("2000",product(admitted,anchor).remainingQty());
        assertEquals(oldPlans,frozenPlans(c.analysis()));assertEquals(before,nonPlanningFacts(c));

        issue(c,material,"2000","child-extra",true);
        issueProduct(c,root,"2000","root-extra");
        qty("0",product(analyses.detail(c.analysis()),root).remainingQty());
        assertThrows(ApiException.class,()->issueProduct(c,root,"1","root-after-full"));
        assertEquals(4,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
        Map<String,String> after=frozenPlans(c.analysis());
        oldPlans.forEach((key,value)->assertEquals(value,after.get(key),"原计划及包未改写: "+key));
        assertEquals(before,nonPlanningFacts(c));
    }

    /**
     * 混合候选一次下达（2 个自制 + 1 个有自制子层的委外）：每行各一张计划、各一条子件锚点
     * （MAKE_COMPONENT / SUBCONTRACT_MAKE）、委外台账一条；batchChildLineIds 一次 IN 按父行映射，
     * 唯一部分索引保证每父至多一子（无重复子件）；同请求重放不重复建行。
     */
    @Test void mixedMakeAndSubcontractCandidatesIssueInOneBatchWithOneAnchorEach(){
        MixedCase c=createMixed("anchor-mixed");
        AnalysisView view=analyses.detail(c.analysis());
        var request=issueRequest(c.analysis(),view,c.world(),"mixed",
                line(c.makeLines().get(0),"6000"),line(c.makeLines().get(1),"6000"),line(c.subcontractLine(),"6000"));
        GenerateResult result=commands.issueWorkshopPlans(c.analysis(),request);
        assertFalse(result.replayed());assertEquals(3,result.plans().size());
        AnalysisView after=analyses.detail(c.analysis());
        for(UUID make:c.makeLines()){
            UUID anchor=material(after,make).planAnchorAnalysisLineId();
            assertNotNull(anchor,"每个自制候选各有一条锚点");
            assertEquals("MAKE_COMPONENT",product(after,anchor).sourceType());
            qty("10000",product(after,anchor).requestedQty());qty("6000",product(after,anchor).approvedQty());
        }
        assertEquals(2,count("SELECT count(*) FROM production_material_analysis_items WHERE analysis_id=? AND source_type='MAKE_COMPONENT' AND is_deleted=FALSE",c.analysis()));
        assertEquals(1,count("SELECT count(*) FROM production_material_analysis_items WHERE analysis_id=? AND source_type='SUBCONTRACT_MAKE' AND is_deleted=FALSE",c.analysis()));
        assertEquals(1,count("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=? AND route='SUBCONTRACT'",c.analysis()));
        assertEquals(3,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
        assertEquals(0,count("SELECT count(*) FROM (SELECT parent_analysis_material_id FROM production_material_analysis_items WHERE analysis_id=? AND source_type IN ('MAKE_COMPONENT','SUBCONTRACT_MAKE') AND is_deleted=FALSE GROUP BY 1 HAVING count(*)>1) dup",c.analysis()));
        var replay=commands.issueWorkshopPlans(c.analysis(),request);
        assertTrue(replay.replayed());
        assertEquals(3,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
    }

    /** 同一批自制候选二次下达：走既有锚点（不新建子件行），只消费剩余配额，计划数累加。 */
    @Test void secondIssueOnTheSameCandidatesReusesExistingAnchorsWithoutNewChildRows(){
        MixedCase c=createMixed("anchor-reuse");
        UUID a=c.makeLines().get(0),b=c.makeLines().get(1);
        commands.issueWorkshopPlans(c.analysis(),issueRequest(c.analysis(),analyses.detail(c.analysis()),c.world(),"first",line(a,"6000"),line(b,"6000")));
        AnalysisView first=analyses.detail(c.analysis());
        // Arrays.asList 允许 null 元素：锚点缺失时走断言失败而不是 List.of 的 NPE。
        List<UUID> anchors=java.util.Arrays.asList(material(first,a).planAnchorAnalysisLineId(),material(first,b).planAnchorAnalysisLineId());
        anchors.forEach(anchor->assertNotNull(anchor,"二次下达前每个自制候选都已有锚点"));
        commands.issueWorkshopPlans(c.analysis(),issueRequest(c.analysis(),first,c.world(),"second",line(a,"4000"),line(b,"4000")));
        AnalysisView second=analyses.detail(c.analysis());
        assertEquals(anchors,List.of(material(second,a).planAnchorAnalysisLineId(),material(second,b).planAnchorAnalysisLineId()));
        assertEquals(2,count("SELECT count(*) FROM production_material_analysis_items WHERE analysis_id=? AND source_type='MAKE_COMPONENT' AND is_deleted=FALSE",c.analysis()));
        assertEquals(4,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
        for(UUID anchor:anchors){qty("10000",product(second,anchor).requestedQty());qty("0",product(second,anchor).remainingQty());}
        assertThrows(ApiException.class,()->commands.issueWorkshopPlans(c.analysis(),issueRequest(c.analysis(),second,c.world(),"third",line(a,"1"))));
        assertEquals(4,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
    }

    /**
     * 两线程分别下达不同候选行（同一版本/指纹）：advisory 锁串行，先到者成功，后到者按 CAS
     * 得 409（不会死锁、不留半截锚点）；失败方用新版本重试成功。最终两条锚点、两张计划、
     * line_priority 互不冲突。
     */
    @Test void twoThreadsIssuingDifferentCandidateLinesSerializeWithoutResidueAndKeepDistinctPriorities() throws Exception{
        Case c=create("anchor-threads",true);UUID first=c.materials().get(0),second=c.materials().get(1);
        AnalysisView view=analyses.detail(c.analysis());
        List<IssueWorkshopPlansRequest> requests=List.of(
                request(c,view,first,"6000","thread-a",true),request(c,view,second,"6000","thread-b",true));
        var workers=Executors.newFixedThreadPool(2);CountDownLatch start=new CountDownLatch(1);
        List<Object> outcomes=new ArrayList<>();
        try{
            var jobs=requests.stream().map(r->workers.submit(()->{
                fixture.loginAs(c.planner());
                try{assertTrue(start.await(30,TimeUnit.SECONDS));return commands.issueWorkshopPlans(c.analysis(),r);}
                finally{SecurityContextHolder.clearContext();}
            })).toList();
            start.countDown();
            for(var job:jobs){
                try{outcomes.add(job.get(120,TimeUnit.SECONDS));}
                catch(java.util.concurrent.ExecutionException e){outcomes.add(e.getCause());}
            }
        }finally{workers.shutdownNow();}
        long successes=outcomes.stream().filter(o->o instanceof GenerateResult).count();
        assertTrue(successes>=1,"至少一个线程成功: "+outcomes);
        outcomes.stream().filter(o->!(o instanceof GenerateResult))
                .forEach(o->assertInstanceOf(ApiException.class,o,"落后线程只能是 CAS/锁冲突，不是其它异常"));
        assertEquals(successes,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
        assertEquals(successes,count("SELECT count(*) FROM production_material_analysis_items WHERE analysis_id=? AND source_type='MAKE_COMPONENT' AND is_deleted=FALSE",c.analysis()));
        for(UUID material:List.of(first,second)){
            if(material(analyses.detail(c.analysis()),material).planAnchorAnalysisLineId()==null){
                issue(c,material,"6000","retry-"+material,true);
            }
        }
        AnalysisView done=analyses.detail(c.analysis());
        assertNotEquals(material(done,first).planAnchorAnalysisLineId(),material(done,second).planAnchorAnalysisLineId());
        assertEquals(2,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
        assertEquals(2,count("SELECT count(DISTINCT line_priority) FROM production_material_analysis_items WHERE analysis_id=? AND source_type='MAKE_COMPONENT' AND is_deleted=FALSE",c.analysis()));
    }

    /** 一行超过剩余需求：整批回滚——无 MAKE_COMPONENT 残留、无计划、版本不变；回滚后同候选可正常下达。 */
    @Test void overQuantityLineRollsBackTheWholeBatchWithoutAnchorResidue(){
        Case c=create("anchor-rollback",true);UUID first=c.materials().get(0),second=c.materials().get(1);
        AnalysisView view=analyses.detail(c.analysis());
        var request=issueRequest(c.analysis(),view,c.world(),"over",line(first,"6000"),line(second,"20000"));
        assertThrows(ApiException.class,()->commands.issueWorkshopPlans(c.analysis(),request));
        assertEquals(0,count("SELECT count(*) FROM production_material_analysis_items WHERE analysis_id=? AND source_type='MAKE_COMPONENT' AND is_deleted=FALSE",c.analysis()));
        assertEquals(0,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
        AnalysisView after=analyses.detail(c.analysis());
        assertNull(material(after,first).planAnchorAnalysisLineId());assertNull(material(after,second).planAnchorAnalysisLineId());
        assertEquals(view.version(),after.version());
        issue(c,first,"6000","after-rollback",true);
        assertEquals(1,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
        assertNotNull(material(analyses.detail(c.analysis()),first).planAnchorAnalysisLineId());
    }

    private static IssueWorkshopPlansRequest.IssuePlanLine line(UUID material,String qty){
        return new IssueWorkshopPlansRequest.IssuePlanLine(material,null,new BigDecimal(qty),null,null,null,null,null,null,null);
    }
    private static IssueWorkshopPlansRequest issueRequest(UUID analysis,AnalysisView view,FullChainEndToEndTest.World w,String key,
                                                          IssueWorkshopPlansRequest.IssuePlanLine...lines){
        return new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"issue-"+analysis+"-"+key,w.warehouseId(),
                BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(lines));
    }

    /** 根 → {P0(自制)→C, P1(自制)→C, S(委外)→C, D(采购)}：两条自制候选 + 一条有自制子层的委外候选。 */
    private MixedCase createMixed(String tag){
        var w=fixture.seedWorld(tag);UUID root=UUID.randomUUID();
        fixture.insertGoods(root,"ROOT-"+tag,"混合候选成品","自制",w.unitId(),w.unitLegacy());
        List<UUID> makeParents=new ArrayList<>();
        for(int i=0;i<2;i++){
            UUID parent=UUID.randomUUID();fixture.insertGoods(parent,"P"+i+"-"+tag,"自制父件"+i,"自制",w.unitId(),w.unitLegacy());
            fixture.insertBom(root,parent,"1");fixture.insertBom(parent,w.goodsC(),"1");makeParents.add(parent);
        }
        UUID sub=UUID.randomUUID();fixture.insertGoods(sub,"S-"+tag,"有自制子层的委外件","委外",w.unitId(),w.unitLegacy());
        fixture.insertBom(root,sub,"1");fixture.insertBom(sub,w.goodsC(),"1");
        fixture.insertBom(root,w.goodsD(),"1");
        UUID planner=fixture.createUserWithPerms(w,"planner-"+tag,
                "production_material_analysis:view","production_material_analysis:manage","production_material_analysis:route",
                "production_material_analysis:notify","production_material_analysis:generate","production_plan:view",
                "production_plan:approve","production_plan:delete");
        fixture.loginAs(planner);
        AnalysisView view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"preview-"+tag,List.of(
                new PreviewItem("OTHER",null,root,null,w.unitId(),"manual-"+tag,"混合候选原始需求",BusinessTime.today().plusDays(10),new BigDecimal("10000")))));
        var routes=view.flatMaterials().stream().map(m->new RouteDecision(m.materialLineId(),m.actionGroupKey(),
                m.goodsId().equals(w.goodsD())?"BUY":m.goodsId().equals(sub)?"SUBCONTRACT":"MAKE",null)).toList();
        analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"routes-"+tag,routes));
        view=analyses.detail(view.analysisId());
        List<UUID> makeLines=view.flatMaterials().stream().filter(m->makeParents.contains(m.goodsId()))
                .map(MaterialView::materialLineId).sorted().toList();
        UUID subLine=view.flatMaterials().stream().filter(m->m.goodsId().equals(sub))
                .map(MaterialView::materialLineId).findFirst().orElseThrow();
        assertEquals(2,makeLines.size());
        return new MixedCase(w,view.analysisId(),makeLines,subLine,planner);
    }
    private record MixedCase(FullChainEndToEndTest.World world,UUID analysis,List<UUID> makeLines,UUID subcontractLine,UUID planner){}

    private GenerateResult issueProduct(Case c,UUID product,String qty,String key){
        AnalysisView view=analyses.detail(c.analysis());
        return commands.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),
                "issue-"+c.analysis()+"-"+key,c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(product,new BigDecimal(qty)))));
    }

    private PreviewRequest salesPreview(Case c,String qty,String key){
        AnalysisView view=analyses.detail(c.analysis());
        return new PreviewRequest(c.analysis(),view.version(),view.fingerprint(),c.world().warehouseId(),
                key+"-"+c.analysis(),List.of(new PreviewItem("SALES_ORDER_ITEM",c.salesItem(),null,null,null,
                null,null,BusinessTime.today().plusDays(10),new BigDecimal(qty))));
    }

    private void confirmSales(UUID order,UUID actor){
        fixture.loginAs(actor);var claim=claims.claim("SALES_ORDER_FINANCE_CONFIRM",order.toString());
        Long revision=db.queryForObject("SELECT finance_review_revision FROM sales_orders WHERE id=?",Long.class,order);
        finance.confirm(order,new com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,revision,claim.claimId()));
    }

    private Map<String,String> frozenPlans(UUID analysis){
        Map<String,String> facts=new LinkedHashMap<>();
        for(UUID plan:db.queryForList("SELECT id FROM production_plans WHERE material_analysis_id=? ORDER BY id",UUID.class,analysis)){
            facts.put(plan+"/header",rows("production_plans","id=?",plan));
            for(String table:List.of("production_plan_items","production_planning_packages","production_execution_segments","production_material_demands"))
                facts.put(plan+"/"+table,rows(table,"plan_id=?",plan));
        }
        return facts;
    }

    private Map<String,String> nonPlanningFacts(Case c){
        Map<String,String> facts=new LinkedHashMap<>();
        facts.put("movement",rows("stock_movements","warehouse_id=?",c.world().warehouseId()));
        facts.put("balance",db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY goods_id,color_id),'[]')::text FROM stock_balances t WHERE warehouse_id=?",String.class,c.world().warehouseId()));
        facts.put("ledger",rows("ar_ap_ledger","TRUE"));
        facts.put("finance",db.queryForObject("SELECT jsonb_build_array(total_original,total_local,finance_confirmed,finance_review_revision)::text FROM sales_orders WHERE id=?",String.class,c.salesOrder()));
        return facts;
    }

    private String rows(String table,String predicate,Object...args){
        return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id),'[]')::text FROM "+table+" t WHERE "+predicate,String.class,args);
    }

    private void addHistoricalMakeAction(Case c,UUID material,UUID anchor){
        AnalysisView view=analyses.detail(c.analysis());MaterialView parent=material(view,material);ProductView child=product(view,anchor);
        UUID action=UUID.randomUUID();UUID actor=db.queryForObject("SELECT created_by FROM production_material_analysis_items WHERE id=?",UUID.class,anchor);
        // MAKE notification is retired at the current API. Preserve its real, guard-checked legacy relation as a fixture.
        new org.springframework.transaction.support.TransactionTemplate(transactionManager).executeWithoutResult(status->{
            db.update("""
                    INSERT INTO preplan_supply_actions(id,analysis_id,warehouse_id,goods_id,color_id,unit_id,need_date,
                        route,requested_qty,status,idempotency_key,action_group_key,request_business_key,generation,
                        request_hash,created_by)
                    VALUES(?,?,?,?,?,?,?,'MAKE',?,'OPEN',?,?,?,1,?,?)
                    """,action,c.analysis(),c.world().warehouseId(),parent.goodsId(),parent.colorId(),parent.unitId(),
                    BusinessTime.today().plusDays(10),child.requestedQty(),"legacy-"+action,parent.actionGroupKey(),
                    PlanningPackageFingerprint.sha256(
                            List.of("PREPLAN-SUPPLY-ACTION-V1",c.analysis().toString(),parent.actionGroupKey(),"MAKE","1")),
                    PlanningPackageFingerprint.sha256(List.of("legacy-action-fixture",action.toString())),actor);
            db.update("INSERT INTO preplan_supply_action_allocations(id,analysis_id,action_id,analysis_material_id,allocated_qty,created_by) VALUES(?,?,?,?,?,?)",
                    UUID.randomUUID(),c.analysis(),action,material,child.requestedQty(),actor);
            db.update("UPDATE preplan_supply_actions SET status='CREATED',external_document_type='PREPLAN_MAKE_TASK',external_document_id=?,external_document_no=? WHERE id=?",
                    anchor,child.sourceRef(),action);
            db.update("UPDATE preplan_supply_action_allocations SET external_item_id=? WHERE action_id=?",anchor,action);
        });
    }

    private Case create(String tag,boolean twoPaths){return create(tag,twoPaths,false,"10000");}
    private Case create(String tag,boolean twoPaths,boolean salesSource,String sourceQty){
        var w=fixture.seedWorld(tag);UUID root=UUID.randomUUID();
        fixture.insertGoods(root,"ROOT-"+tag,"锚点回归成品","自制",w.unitId(),w.unitLegacy());
        if(twoPaths){
            for(int i=0;i<2;i++){
                UUID parent=UUID.randomUUID();fixture.insertGoods(parent,"P"+i+"-"+tag,"独立父路径","自制",w.unitId(),w.unitLegacy());
                fixture.insertBom(root,parent,"1");fixture.insertBom(parent,w.goodsC(),"1");
            }
        }else fixture.insertBom(root,w.goodsC(),"1");
        fixture.insertBom(root,w.goodsD(),"1");
        UUID salesOrder=null,salesItem=null,salesActor=null,financeActor=null;
        if(salesSource){
            salesActor=fixture.createUserWithPerms(w,"seller-"+tag,"sales_order:create","sales_order:view","sales_order:approve","sales_order:change_qty","sales_order:change_planned");
            financeActor=fixture.createUserWithPerms(w,"finance-"+tag,"sales_order_finance:view","sales_order_finance:confirm");
            db.update("UPDATE clients SET owner_employee_id=(SELECT employee_id FROM users WHERE id=?) WHERE id=?",salesActor,w.clientId());
            fixture.loginAs(salesActor);salesOrder=sales.create(fixture.orderRequest(w,root,sourceQty,"100")).getId();
            sales.approve(salesOrder);confirmSales(salesOrder,financeActor);
            salesItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,salesOrder);
        }
        UUID planner=fixture.createUserWithPerms(w,"planner-"+tag,
                "production_material_analysis:view","production_material_analysis:manage","production_material_analysis:route",
                "production_material_analysis:notify","production_material_analysis:generate","production_plan:view",
                "production_plan:approve","production_plan:delete");
        fixture.loginAs(planner);
        String source="manual-"+tag;
        PreviewItem sourceItem=salesSource
                ?new PreviewItem("SALES_ORDER_ITEM",salesItem,null,null,null,null,null,BusinessTime.today().plusDays(10),new BigDecimal(sourceQty))
                :new PreviewItem("OTHER",null,root,null,w.unitId(),source,"明确的原始生产需求",BusinessTime.today().plusDays(10),new BigDecimal(sourceQty));
        AnalysisView view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"preview-"+tag,List.of(sourceItem)));
        var routes=view.flatMaterials().stream().map(m->new RouteDecision(m.materialLineId(),m.actionGroupKey(),
                m.goodsId().equals(w.goodsD())?"BUY":"MAKE",null)).toList();
        analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"routes-"+tag,routes));
        view=analyses.detail(view.analysisId());
        List<UUID> materialIds=view.flatMaterials().stream().filter(m->m.goodsId().equals(w.goodsC()))
                .map(MaterialView::materialLineId).sorted().toList();
        assertEquals(twoPaths?2:1,materialIds.size());
        return new Case(w,view.analysisId(),root,source,materialIds,planner,salesOrder,salesItem,salesActor,financeActor);
    }
    private GenerateResult issue(Case c,UUID material,String qty,String key,boolean approve){
        AnalysisView view=analyses.detail(c.analysis());
        return commands.issueWorkshopPlans(c.analysis(),request(c,view,material,qty,key,approve));
    }
    private static IssueWorkshopPlansRequest request(Case c,AnalysisView view,UUID material,String qty,String key,boolean approve){
        return new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"issue-"+c.analysis()+"-"+key,
                c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),approve,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(material,null,new BigDecimal(qty),null,null,null,null,null,null,null)));
    }
    private void assertQuotaAndPlans(Case c,UUID anchor,String qty,int expectedPlans){
        qty(qty,product(analyses.detail(c.analysis()),anchor).requestedQty());
        assertEquals(expectedPlans,count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()));
    }
    private static MaterialView material(AnalysisView view,UUID id){return view.flatMaterials().stream().filter(m->m.materialLineId().equals(id)).findFirst().orElseThrow();}
    private static ProductView product(AnalysisView view,UUID id){return view.products().stream().filter(p->p.analysisLineId().equals(id)).findFirst().orElseThrow();}
    private int count(String sql,UUID id){return db.queryForObject(sql,Integer.class,id);}
    private static void qty(String expected,BigDecimal actual){assertEquals(0,new BigDecimal(expected).compareTo(actual));}
    private record Case(FullChainEndToEndTest.World world,UUID analysis,UUID root,String sourceRef,List<UUID> materials,
                        UUID planner,UUID salesOrder,UUID salesItem,UUID salesActor,UUID financeActor){}
}
