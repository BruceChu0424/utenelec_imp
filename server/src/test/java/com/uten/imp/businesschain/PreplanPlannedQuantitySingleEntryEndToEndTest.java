package com.uten.imp.businesschain;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
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

/**
 * ADR-099 计划量单一入口(2026-09-21)的真库回归：顶层按本批数量下达车间后下层需求按
 * 计划产出量放大、既有自制锚点配额自动增长；下达采购「填多少下多少」由服务端分账；
 * 申请明细未订货时追加就地改大(V640)、已订货后另立新申请；下达时自动认领同主仓公共
 * 在途；下达预览真实跑一遍再整体回滚、库里一行不留。
 *
 * <p><b>CI 必须显式设置 {@code UTEN_RUN_DB_TESTS=true}</b>，否则本类全部 SKIP。
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class PreplanPlannedQuantitySingleEntryEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    private FullChainEndToEndTest fixture;
    @BeforeEach void prepare() { fixture=new FullChainEndToEndTest();beans.autowireBean(fixture); }

    /** 根(自制 1000) → P(自制) → C(采购)；根 → D(采购)。全部用量 1，路线已确认。 */
    private record Tree(FullChainEndToEndTest.World world,UUID analysis,UUID root,UUID parent,UUID rootLine,UUID parentLine,UUID childLine,UUID buyLine) {}

    private Tree seed(String tag) { return seed(tag,null,"1000"); }
    private Tree seed(String tag,UUID warehouse,String qty) {
        var w=fixture.seedWorld("planned-qty-"+tag);fixture.loginAs(w.superAdminUserId());
        UUID root=UUID.randomUUID(),parent=UUID.randomUUID();
        fixture.insertGoods(root,"PQ-ROOT-"+root,"计划量成品","自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(parent,"PQ-P-"+parent,"计划量自制父件","自制",w.unitId(),w.unitLegacy());
        fixture.insertBom(root,parent,"1");fixture.insertBom(parent,w.goodsC(),"1");fixture.insertBom(root,w.goodsD(),"1");
        db.update("UPDATE goods SET default_supplier_id=? WHERE id IN (?,?)",w.supplierId(),w.goodsC(),w.goodsD());
        UUID scope=warehouse==null?w.warehouseId():warehouse;
        AnalysisView view=analyses.preview(new PreviewRequest(null,null,null,scope,"planned-preview-"+tag+"-"+root,
                List.of(new PreviewItem("OTHER",null,root,null,w.unitId(),"planned-source-"+tag+"-"+root,"计划量单一入口",BusinessTime.today().plusDays(10),new BigDecimal(qty)))));
        view=analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"planned-routes-"+view.analysisId(),
                view.flatMaterials().stream().filter(MaterialView::actionable)
                        .map(m->new RouteDecision(m.materialLineId(),m.actionGroupKey(),m.goodsId().equals(parent)||m.goodsId().equals(root)?"MAKE":"BUY",null)).toList()));
        return new Tree(w,view.analysisId(),root,parent,view.products().getFirst().analysisLineId(),
                line(view,parent),line(view,w.goodsC()),line(view,w.goodsD()));
    }

    @Test void topOverQuantityIssueScalesChildrenByPlannedOutputAndGrowsTheMakeAnchorQuota() {
        Tree t=seed("planned-output");
        AnalysisView before=analyses.detail(t.analysis());
        qty("1000",material(before,t.parentLine()).requiredQty());qty("1000",material(before,t.parentLine()).plannedOutputQty());
        qty("1000",material(before,t.childLine()).requiredQty());qty("1000",material(before,t.buyLine()).requiredQty());
        // 先把自制父件的候选下达成锚点(全部剩余需求 1000)。
        commands.issueWorkshopPlans(t.analysis(),issue(before,t,"parent-anchor",candidate(t.parentLine(),"1000")));
        AnalysisView anchored=analyses.detail(t.analysis());
        UUID anchor=material(anchored,t.parentLine()).planAnchorAnalysisLineId();
        assertNotNull(anchor);qty("1000",product(anchored,anchor).requestedQty());qty("0",product(anchored,anchor).remainingQty());
        // 顶层按 1500 下达车间(超出需求 500)：一张计划、link 分账 1000 + 500。
        commands.issueWorkshopPlans(t.analysis(),issue(anchored,t,"root-over",new IssueWorkshopPlansRequest.IssuePlanLine(t.rootLine(),new BigDecimal("1500"))));
        Object[] link=db.queryForObject("SELECT submitted_qty,public_surplus_qty FROM production_material_analysis_plan_links WHERE analysis_id=? AND analysis_item_id=?",
                (rs,i)->new Object[]{rs.getBigDecimal(1),rs.getBigDecimal(2)},t.analysis(),t.rootLine());
        qty("1000",(BigDecimal)link[0]);qty("500",(BigDecimal)link[1]);
        AnalysisView after=analyses.detail(t.analysis());
        // 下层按计划产出量 1500 展开：自制父件、其子件、采购件的需求全部随之放大。
        qty("1500",material(after,t.parentLine()).plannedOutputQty());qty("1500",material(after,t.parentLine()).requiredQty());
        qty("1500",material(after,t.childLine()).requiredQty());qty("1500",material(after,t.buyLine()).requiredQty());
        qty("1500",material(after,t.buyLine()).additionalSupplyRecommendedQty());
        // 既有自制锚点的配额自动跟到 1500：车间桶里还能再排 500，不用重新建锚。
        qty("1500",product(after,anchor).requestedQty());qty("500",product(after,anchor).remainingQty());
        assertTrue(product(after,anchor).canSchedule());
        // 孙层的计划产出量 = max(需求, 自家锚点已下达)：需求已随父件放到 1500，再把锚点余下 500 排掉也不再变。
        qty("1500",material(after,t.childLine()).plannedOutputQty());
        commands.issueWorkshopPlans(t.analysis(),issue(after,t,"anchor-rest",new IssueWorkshopPlansRequest.IssuePlanLine(anchor,new BigDecimal("500"))));
        AnalysisView done=analyses.detail(t.analysis());
        qty("0",product(done,anchor).remainingQty());qty("1500",material(done,t.childLine()).plannedOutputQty());
        qty("1500",material(done,t.parentLine()).plannedOutputQty());
        assertEquals(3,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,t.analysis()));
    }

    @Test void issuePreviewRunsTheRealCommandThenRollsBackEverything() {
        Tree t=seed("preview");
        AnalysisView before=analyses.detail(t.analysis());
        AnalysisView preview=commands.previewIssueWorkshopPlans(t.analysis(),issue(before,t,"preview-root",new IssueWorkshopPlansRequest.IssuePlanLine(t.rootLine(),new BigDecimal("1500"))));
        // 预览结果就是真实下达后的样子：下层需求已按 1500 展开。
        qty("1500",material(preview,t.parentLine()).requiredQty());qty("1500",material(preview,t.childLine()).requiredQty());
        qty("1500",material(preview,t.buyLine()).requiredQty());
        // 库里一行不留：计划、link、命令记录、版本号全部还原。
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,t.analysis()));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_material_analysis_plan_links WHERE analysis_id=?",Integer.class,t.analysis()));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_material_analysis_commands WHERE analysis_id=? AND idempotency_key LIKE 'planned-issue-%preview-root'",Integer.class,t.analysis()));
        AnalysisView after=analyses.detail(t.analysis());
        assertEquals(before.version(),after.version());assertEquals(before.fingerprint(),after.fingerprint());
        qty("1000",material(after,t.parentLine()).requiredQty());qty("1000",material(after,t.childLine()).requiredQty());
        // 同一个幂等键可以再预览，也可以随后真实下达。
        commands.previewIssueWorkshopPlans(t.analysis(),issue(after,t,"preview-root",new IssueWorkshopPlansRequest.IssuePlanLine(t.rootLine(),new BigDecimal("1500"))));
        commands.issueWorkshopPlans(t.analysis(),issue(analyses.detail(t.analysis()),t,"preview-root",new IssueWorkshopPlansRequest.IssuePlanLine(t.rootLine(),new BigDecimal("1500"))));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,t.analysis()));
        qty("1500",material(analyses.detail(t.analysis()),t.parentLine()).requiredQty());
    }

    @Test void secondNotifyGrowsTheUnorderedRequestLineInPlaceAndOrderedLinesGetANewRequest() {
        Tree t=seed("grow");var w=t.world();
        AnalysisView view=analyses.detail(t.analysis());
        view=commands.notifySupply(t.analysis(),notify(view,t,"first-600","600"));
        UUID firstAction=db.queryForObject("SELECT id FROM preplan_supply_actions WHERE analysis_id=? AND route='BUY' AND operation_type='SUPPLY'",UUID.class,t.analysis());
        UUID firstItem=db.queryForObject("SELECT external_item_id FROM preplan_supply_action_allocations WHERE action_id=?",UUID.class,firstAction);
        qty("600",db.queryForObject("SELECT qty FROM purchase_request_items WHERE id=?",BigDecimal.class,firstItem));
        qty("400",material(view,t.buyLine()).additionalSupplyRecommendedQty());
        // 申请还没人动过：追加 400 直接改到同一条明细上，不另立新单。
        view=commands.notifySupply(t.analysis(),notify(view,t,"second-400","400"));
        qty("1000",db.queryForObject("SELECT qty FROM purchase_request_items WHERE id=?",BigDecimal.class,firstItem));
        qty("1000",db.queryForObject("SELECT requested_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,firstAction));
        qty("1000",db.queryForObject("SELECT SUM(allocated_qty) FROM preplan_supply_action_allocations WHERE action_id=?",BigDecimal.class,firstAction));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SUPPLY'",Integer.class,t.analysis()));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM purchase_requests WHERE id IN (SELECT request_id FROM purchase_request_items WHERE id=?)",Integer.class,firstItem));
        assertEquals(1,db.queryForObject("SELECT jsonb_array_length(result_payload->'grownActionIds') FROM production_material_analysis_commands WHERE analysis_id=? AND idempotency_key=?",Integer.class,t.analysis(),"planned-notify-"+t.analysis()+"-second-400"));
        qty("0",material(view,t.buyLine()).additionalSupplyRecommendedQty());
        // 追加后按单据再提醒一次(单号 + 追加量)，走业务 outbox。
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM business_outbox WHERE aggregate_id=? AND payload->>'addedQty'='400'",Integer.class,
                db.queryForObject("SELECT request_id FROM purchase_request_items WHERE id=?",UUID.class,firstItem)));
        // 采购部把这条明细分解成订货单(哪怕还在等财务审核)之后，它就不能再被改大。
        approveOrder(w,firstItem,w.goodsD(),"1000",BusinessTime.today().plusDays(5));
        fixture.loginAs(w.superAdminUserId());
        view=analyses.detail(t.analysis());
        commands.issueWorkshopPlans(t.analysis(),issue(view,t,"root-over",new IssueWorkshopPlansRequest.IssuePlanLine(t.rootLine(),new BigDecimal("1500"))));
        view=analyses.detail(t.analysis());
        qty("1500",material(view,t.buyLine()).requiredQty());qty("500",material(view,t.buyLine()).additionalSupplyRecommendedQty());
        view=commands.notifySupply(t.analysis(),notify(view,t,"third-500","500"));
        qty("1000",db.queryForObject("SELECT qty FROM purchase_request_items WHERE id=?",BigDecimal.class,firstItem));
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SUPPLY'",Integer.class,t.analysis()));
        assertEquals(2,db.queryForObject("SELECT COUNT(DISTINCT item.request_id) FROM purchase_request_items item JOIN preplan_supply_action_allocations allocation ON allocation.external_item_id=item.id JOIN preplan_supply_actions action ON action.id=allocation.action_id WHERE action.analysis_id=?",Integer.class,t.analysis()));
        qty("0",material(view,t.buyLine()).additionalSupplyRecommendedQty());
    }

    @Test void appendingOnAFullyCoveredLineGrowsTheUnorderedRequestAsPurePublicSurplus() {
        Tree t=seed("append-public");
        AnalysisView view=analyses.detail(t.analysis());
        // 需求 1000 一次下满：还需安排归零。
        view=commands.notifySupply(t.analysis(),notify(view,t,"full-1000","1000"));
        UUID action=db.queryForObject("SELECT id FROM preplan_supply_actions WHERE analysis_id=? AND route='BUY' AND operation_type='SUPPLY'",UUID.class,t.analysis());
        UUID item=db.queryForObject("SELECT external_item_id FROM preplan_supply_action_allocations WHERE action_id=?",UUID.class,action);
        qty("0",material(view,t.buyLine()).additionalSupplyRecommendedQty());
        qty("1000",db.queryForObject("SELECT qty FROM purchase_request_items WHERE id=?",BigDecimal.class,item));
        // 采购还没处理这张申请：再追加 200 全是公共备货，直接改大同一条明细，不另立新单。
        view=commands.notifySupply(t.analysis(),notify(view,t,"append-200","200"));
        qty("1200",db.queryForObject("SELECT qty FROM purchase_request_items WHERE id=?",BigDecimal.class,item));
        Object[] split=db.queryForObject("SELECT requested_qty,public_surplus_qty FROM preplan_supply_actions WHERE id=?",
                (rs,i)->new Object[]{rs.getBigDecimal(1),rs.getBigDecimal(2)},action);
        qty("1000",(BigDecimal)split[0]);qty("200",(BigDecimal)split[1]);
        // 公共份锚到同一条明细(V588 合并明细形态)；需求侧分摊一分不动。
        assertEquals(item,db.queryForObject("SELECT public_surplus_external_item_id FROM preplan_supply_actions WHERE id=?",UUID.class,action));
        qty("1000",db.queryForObject("SELECT SUM(allocated_qty) FROM preplan_supply_action_allocations WHERE action_id=?",BigDecimal.class,action));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SUPPLY'",Integer.class,t.analysis()));
        qty("0",material(analyses.detail(t.analysis()),t.buyLine()).additionalSupplyRecommendedQty());
        // 采购一旦分解出订货单，同样的追加只能另立新申请。
        approveOrder(t.world(),item,t.world().goodsD(),"1200",BusinessTime.today().plusDays(5));
        fixture.loginAs(t.world().superAdminUserId());
        view=analyses.detail(t.analysis());
        commands.notifySupply(t.analysis(),notify(view,t,"append-after-order-50","50"));
        qty("1200",db.queryForObject("SELECT qty FROM purchase_request_items WHERE id=?",BigDecimal.class,item));
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SUPPLY'",Integer.class,t.analysis()));
    }

    @Test void notifyTakesTheTypedTotalAndSplitsDemandFromPublicExtraOnTheServer() {
        Tree t=seed("split");
        AnalysisView view=analyses.detail(t.analysis());
        view=commands.notifySupply(t.analysis(),notify(view,t,"typed-1200","1200"));
        Object[] action=db.queryForObject("SELECT requested_qty,public_surplus_qty FROM preplan_supply_actions WHERE analysis_id=? AND route='BUY' AND operation_type='SUPPLY'",
                (rs,i)->new Object[]{rs.getBigDecimal(1),rs.getBigDecimal(2)},t.analysis());
        qty("1000",(BigDecimal)action[0]);qty("200",(BigDecimal)action[1]);
        UUID item=db.queryForObject("SELECT external_item_id FROM preplan_supply_action_allocations WHERE action_id=(SELECT id FROM preplan_supply_actions WHERE analysis_id=? AND route='BUY' AND operation_type='SUPPLY')",UUID.class,t.analysis());
        qty("1200",db.queryForObject("SELECT qty FROM purchase_request_items WHERE id=?",BigDecimal.class,item));
        qty("0",material(view,t.buyLine()).additionalSupplyRecommendedQty());
    }

    @Test void notifyClaimsSameMainWarehousePublicInTransitBeforeOrderingTheRest() {
        // A 在子仓：买 100，订货 1000 → 900 公共在途；B 在主仓需要 1000。
        Tree a=seed("claim-source");var w=a.world();
        UUID main=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,status) VALUES(?,?,?,'使用')",main,"PQ-MAIN-"+main,"计划量公共在途主仓");
        db.update("UPDATE warehouses SET parent_id=? WHERE id=?",main,w.warehouseId());
        AnalysisView sourceView=analyses.detail(a.analysis());
        commands.notifySupply(a.analysis(),notify(sourceView,a,"source-100","100"));
        UUID sourceItem=db.queryForObject("SELECT allocation.external_item_id FROM preplan_supply_actions action JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id WHERE action.analysis_id=? AND action.route='BUY'",UUID.class,a.analysis());
        approveOrder(w,sourceItem,w.goodsD(),"1000",BusinessTime.today().plusDays(5));
        fixture.loginAs(w.superAdminUserId());
        UUID receiverRoot=UUID.randomUUID();
        fixture.insertGoods(receiverRoot,"PQ-RECV-"+receiverRoot,"公共在途受益成品","自制",w.unitId(),w.unitLegacy());
        fixture.insertBom(receiverRoot,w.goodsD(),"1");
        AnalysisView b=analyses.preview(new PreviewRequest(null,null,null,main,"planned-receiver-"+receiverRoot,
                List.of(new PreviewItem("OTHER",null,receiverRoot,null,w.unitId(),"planned-receiver-source-"+receiverRoot,"公共在途受益",BusinessTime.today().plusDays(10),new BigDecimal("1000")))));
        b=analyses.saveRoutes(b.analysisId(),new RouteRequest(b.version(),b.fingerprint(),"planned-receiver-routes-"+b.analysisId(),
                b.flatMaterials().stream().filter(MaterialView::actionable).map(m->new RouteDecision(m.materialLineId(),m.actionGroupKey(),m.goodsId().equals(receiverRoot)?"MAKE":"BUY",null)).toList()));
        UUID buyLine=line(b,w.goodsD());
        qty("900",material(b,buyLine).sharedFutureClaimableQty());qty("1000",material(b,buyLine).additionalSupplyRecommendedQty());
        final UUID receiver=b.analysisId();
        AnalysisView claimed=commands.notifySupply(receiver,new NotifyRequest(b.version(),b.fingerprint(),"planned-claim-notify-"+receiver,"BUY",
                List.of(buyLine),List.of(),List.of(new SupplyQuantityInput(null,buyLine,new BigDecimal("1000"),BigDecimal.ZERO))));
        // 先认领 900 公共在途，只为余下 100 新下采购申请；两个动作记在同一条命令里。
        qty("900",db.queryForObject("SELECT SUM(requested_qty) FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SHARED_FUTURE_CLAIM'",BigDecimal.class,receiver));
        qty("100",db.queryForObject("SELECT SUM(requested_qty) FROM preplan_supply_actions WHERE analysis_id=? AND operation_type='SUPPLY'",BigDecimal.class,receiver));
        qty("900",material(claimed,buyLine).sharedFuturePendingQty());qty("0",material(claimed,buyLine).additionalSupplyRecommendedQty());
        qty("0",material(claimed,buyLine).sharedFutureClaimableQty());
        assertEquals(1,db.queryForObject("SELECT jsonb_array_length(result_payload->'claimActionIds') FROM production_material_analysis_commands WHERE analysis_id=? AND idempotency_key=?",Integer.class,receiver,"planned-claim-notify-"+receiver));
        qty("0",db.queryForObject("SELECT available_to_claim_qty FROM v_preplan_public_surplus_source_state WHERE source_action_id=(SELECT id FROM preplan_supply_actions WHERE analysis_id=? AND route='BUY')",BigDecimal.class,a.analysis()));
        // 幂等重放不重复认领、不重复下单。
        commands.notifySupply(receiver,new NotifyRequest(b.version(),b.fingerprint(),"planned-claim-notify-"+receiver,"BUY",
                List.of(buyLine),List.of(),List.of(new SupplyQuantityInput(null,buyLine,new BigDecimal("1000"),BigDecimal.ZERO))));
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM preplan_supply_actions WHERE analysis_id=?",Integer.class,receiver));
    }

    @Test void fullyPlannedMakeAnchorCanStillIssueAPureSurplusBatchThatDrivesItsChildren() {
        Tree t=seed("surplus-anchor");
        AnalysisView before=analyses.detail(t.analysis());
        commands.issueWorkshopPlans(t.analysis(),issue(before,t,"parent-anchor",candidate(t.parentLine(),"1000")));
        AnalysisView anchored=analyses.detail(t.analysis());
        UUID anchor=material(anchored,t.parentLine()).planAnchorAnalysisLineId();
        // 需求已全部转入计划：不能按需求再排(canSchedule=false)，但可以再下一批纯公共备货产出。
        assertFalse(product(anchored,anchor).canSchedule());assertTrue(product(anchored,anchor).canIssueSurplus());
        qty("1000",product(anchored,anchor).issuedPlanQty());
        // 不声明 publicSurplusOnly 照旧 409(重复点击不能悄悄多建计划)；声明后按纯公共备货产出放行。
        assertThrows(com.uten.imp.common.web.ApiException.class,()->commands.issueWorkshopPlans(t.analysis(),
                issue(anchored,t,"anchor-surplus-implicit",new IssueWorkshopPlansRequest.IssuePlanLine(anchor,new BigDecimal("200")))));
        commands.issueWorkshopPlans(t.analysis(),issue(anchored,t,"anchor-surplus",
                new IssueWorkshopPlansRequest.IssuePlanLine(null,anchor,new BigDecimal("200"),null,null,null,null,null,null,null,Boolean.TRUE)));
        Object[] link=db.queryForObject("SELECT submitted_qty,public_surplus_qty FROM production_material_analysis_plan_links WHERE analysis_id=? AND analysis_item_id=? ORDER BY created_at DESC LIMIT 1",
                (rs,i)->new Object[]{rs.getBigDecimal(1),rs.getBigDecimal(2)},t.analysis(),anchor);
        qty("0",(BigDecimal)link[0]);qty("200",(BigDecimal)link[1]);
        AnalysisView after=analyses.detail(t.analysis());
        // 锚点需求不变(仍 1000)，已下达计划量 1200；子件按锚点计划产出量 1200 展开。
        qty("1000",product(after,anchor).requestedQty());qty("1200",product(after,anchor).issuedPlanQty());
        qty("1200",material(after,t.parentLine()).plannedOutputQty());qty("1200",material(after,t.childLine()).requiredQty());
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,t.analysis()));
        // 下游引用带「申请明细仍未订货」的当前数量：采购件下 600 后可就地改大；订货后为空。
        AnalysisView notified=commands.notifySupply(t.analysis(),notify(after,t,"buy-600","600"));
        var reference=material(notified,t.buyLine()).downstreamReferences().stream().filter(r->"BUY".equals(r.route())).findFirst().orElseThrow();
        qty("600",reference.growableLineQty());
        UUID item=db.queryForObject("SELECT external_item_id FROM preplan_supply_action_allocations WHERE action_id=?",UUID.class,reference.actionId());
        approveOrder(t.world(),item,t.world().goodsD(),"600",BusinessTime.today().plusDays(5));
        fixture.loginAs(t.world().superAdminUserId());
        var ordered=material(analyses.detail(t.analysis()),t.buyLine()).downstreamReferences().stream().filter(r->"BUY".equals(r.route())).findFirst().orElseThrow();
        assertNull(ordered.growableLineQty());
    }

    /** 根(自制) -> S(委外, 有自制子层) -> {C(自制), D(采购)}。 */
    private record SubTree(FullChainEndToEndTest.World world,UUID analysis,UUID subLine) {}

    private SubTree seedSubcontract(String tag) {
        var w=fixture.seedWorld("planned-sub-"+tag);fixture.loginAs(w.superAdminUserId());
        UUID root=UUID.randomUUID(),sub=UUID.randomUUID();
        fixture.insertGoods(root,"PQS-ROOT-"+root,"委外追加成品","自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(sub,"PQS-S-"+sub,"有自制子层的委外件","委外",w.unitId(),w.unitLegacy());
        fixture.insertBom(root,sub,"1");fixture.insertBom(sub,w.goodsC(),"1");fixture.insertBom(sub,w.goodsD(),"1");
        db.update("UPDATE goods SET default_supplier_id=? WHERE id=?",w.supplierId(),w.goodsD());
        AnalysisView view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"planned-sub-preview-"+tag+"-"+root,
                List.of(new PreviewItem("OTHER",null,root,null,w.unitId(),"planned-sub-source-"+tag+"-"+root,"委外追加",BusinessTime.today().plusDays(10),new BigDecimal("1000")))));
        view=analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"planned-sub-routes-"+view.analysisId(),
                view.flatMaterials().stream().filter(MaterialView::actionable)
                        .map(m->new RouteDecision(m.materialLineId(),m.actionGroupKey(),
                                m.goodsId().equals(sub)?"SUBCONTRACT":m.goodsId().equals(w.goodsD())?"BUY":"MAKE",null)).toList()));
        return new SubTree(w,view.analysisId(),line(view,sub));
    }

    @Test void subcontractWithMakeChildrenCanAppendAPurePublicSurplusBatchThroughArrange() {
        SubTree t=seedSubcontract("append");
        AnalysisView view=analyses.detail(t.analysis());
        qty("1000",material(view,t.subLine()).additionalSupplyRecommendedQty());
        // 第一次按需求 1000 下达车间：ARRANGE 建前置自制台账 + 锚点 + 计划。
        commands.issueWorkshopPlans(t.analysis(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),
                "planned-sub-issue-"+t.analysis()+"-first",t.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(candidate(t.subLine(),"1000"))));
        AnalysisView issued=analyses.detail(t.analysis());
        UUID anchor=material(issued,t.subLine()).planAnchorAnalysisLineId();
        assertNotNull(anchor);
        qty("0",material(issued,t.subLine()).additionalSupplyRecommendedQty());
        assertFalse(product(issued,anchor).canSchedule());assertTrue(product(issued,anchor).canIssueSurplus());
        qty("1000",db.queryForObject("SELECT required_qty FROM preplan_subcontract_make_tasks WHERE analysis_id=?",BigDecimal.class,t.analysis()));
        // 不声明 publicSurplusOnly 照旧 409；声明后按纯公共备货产出追加 200。
        assertThrows(com.uten.imp.common.web.ApiException.class,()->commands.issueWorkshopPlans(t.analysis(),
                new IssueWorkshopPlansRequest(issued.version(),issued.fingerprint(),"planned-sub-issue-"+t.analysis()+"-implicit",
                        t.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                        List.of(candidate(t.subLine(),"200")))));
        AnalysisView before=analyses.detail(t.analysis());
        commands.issueWorkshopPlans(t.analysis(),new IssueWorkshopPlansRequest(before.version(),before.fingerprint(),
                "planned-sub-issue-"+t.analysis()+"-append",t.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(t.subLine(),null,new BigDecimal("200"),null,null,null,null,null,null,null,Boolean.TRUE))));
        AnalysisView after=analyses.detail(t.analysis());
        // 台账跟量到 1200；追加那笔全记公共备货，需求侧一分不多占。
        qty("1200",db.queryForObject("SELECT required_qty FROM preplan_subcontract_make_tasks WHERE analysis_id=?",BigDecimal.class,t.analysis()));
        qty("0",material(after,t.subLine()).additionalSupplyRecommendedQty());
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,t.analysis()));
        Object[] link=db.queryForObject("SELECT submitted_qty,public_surplus_qty FROM production_material_analysis_plan_links WHERE analysis_id=? AND analysis_item_id=? ORDER BY created_at DESC LIMIT 1",
                (rs,i)->new Object[]{rs.getBigDecimal(1),rs.getBigDecimal(2)},t.analysis(),anchor);
        qty("0",(BigDecimal)link[0]);qty("200",(BigDecimal)link[1]);
    }

    private static IssueWorkshopPlansRequest.IssuePlanLine candidate(UUID material,String qty) {
        return new IssueWorkshopPlansRequest.IssuePlanLine(material,null,new BigDecimal(qty),null,null,null,null,null,null,null);
    }
    private static IssueWorkshopPlansRequest issue(AnalysisView view,Tree t,String key,IssueWorkshopPlansRequest.IssuePlanLine... lines) {
        return new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"planned-issue-"+t.analysis()+"-"+key,t.world().warehouseId(),
                BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(lines));
    }
    private static NotifyRequest notify(AnalysisView view,Tree t,String key,String qty) {
        return new NotifyRequest(view.version(),view.fingerprint(),"planned-notify-"+t.analysis()+"-"+key,"BUY",List.of(t.buyLine()),List.of(),
                List.of(new SupplyQuantityInput(null,t.buyLine(),new BigDecimal(qty),BigDecimal.ZERO)));
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
    private static UUID line(AnalysisView view,UUID goods) {
        return view.flatMaterials().stream().filter(m->m.goodsId().equals(goods)).map(MaterialView::materialLineId).findFirst()
                .orElseThrow(()->new IllegalStateException("goods "+goods+" missing in "+view.flatMaterials().stream()
                        .map(m->m.goodsId()+"/"+m.goodsName()+"/"+m.nodeRole()+"/"+m.sourceConfirmed()).toList()));
    }
    private static MaterialView material(AnalysisView view,UUID line) { return view.flatMaterials().stream().filter(m->m.materialLineId().equals(line)).findFirst().orElseThrow(); }
    private static ProductView product(AnalysisView view,UUID line) { return view.products().stream().filter(p->p.analysisLineId().equals(line)).findFirst().orElseThrow(); }
    private static void qty(String expected,BigDecimal actual) { assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+", actual "+actual); }
}
