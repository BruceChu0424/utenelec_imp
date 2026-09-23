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
        // 2026-09-23：锚点已排满, 物料行「还缺数量」扣掉归需求的计划量归 0; 「还需安排」按契约仍是毛缺口。
        qty("0",material(anchored,t.parentLine()).netShortageQty());
        qty("1000",material(anchored,t.parentLine()).additionalSupplyRecommendedQty());
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
        // 需求涨到 1500、计划只归了 1000: 还缺 500, 与锚点余量同口径。
        qty("500",material(after,t.parentLine()).netShortageQty());
        // 孙层的计划产出量 = max(需求, 自家锚点已下达)：需求已随父件放到 1500，再把锚点余下 500 排掉也不再变。
        qty("1500",material(after,t.childLine()).plannedOutputQty());
        var rest=commands.issueWorkshopPlans(t.analysis(),issue(after,t,"anchor-rest",new IssueWorkshopPlansRequest.IssuePlanLine(anchor,new BigDecimal("500"))));
        AnalysisView done=analyses.detail(t.analysis());
        qty("0",product(done,anchor).remainingQty());qty("1500",material(done,t.childLine()).plannedOutputQty());
        qty("0",material(done,t.parentLine()).netShortageQty());
        qty("1500",material(done,t.parentLine()).plannedOutputQty());
        // ADR-104：锚点那张计划已审核但车间没领料没开工, 余下 500 并进同一张(1000→1500), 不另立;
        // 顶层 1500 那张是另一个分析行的计划——全分析共两张。
        assertTrue(rest.plans().getFirst().mergedIntoExisting());
        qty("1500",db.queryForObject("SELECT item.qty FROM production_plan_items item JOIN production_plans plan ON plan.id=item.plan_id WHERE plan.material_analysis_item_id=? AND item.is_deleted=FALSE",BigDecimal.class,anchor));
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,t.analysis()));
    }

    @Test void issuePreviewRunsTheRealCommandThenRollsBackEverything() {
        Tree t=seed("preview");
        AnalysisView before=analyses.detail(t.analysis());
        AnalysisView preview=commands.previewIssuePlans(t.analysis(),previewOf(issue(before,t,"preview-root",new IssueWorkshopPlansRequest.IssuePlanLine(t.rootLine(),new BigDecimal("1500")))));
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
        commands.previewIssuePlans(t.analysis(),previewOf(issue(after,t,"preview-root",new IssueWorkshopPlansRequest.IssuePlanLine(t.rootLine(),new BigDecimal("1500")))));
        commands.issueWorkshopPlans(t.analysis(),issue(analyses.detail(t.analysis()),t,"preview-root",new IssueWorkshopPlansRequest.IssuePlanLine(t.rootLine(),new BigDecimal("1500"))));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,t.analysis()));
        qty("1500",material(analyses.detail(t.analysis()),t.parentLine()).requiredQty());
    }

    /**
     * ADR-107 评审补充：下达车间预览真实跑一遍下达(建计划、审核、写预留)再整体回滚, 主仓协调锁改取
     * 共享模式后, 同一主仓两份分析的预览会同时写。两边反复同时预览：都成功、不互相等死或死锁,
     * 库里一行不留。
     */
    @Test void concurrentIssuePreviewsInTheSameMainWarehouseBothSucceedAndLeaveNothing() throws Exception {
        Tree a=seed("parallel-preview-a");
        UUID warehouse=a.world().warehouseId();
        Tree b=seed("parallel-preview-b",warehouse,"1000");
        AnalysisView beforeA=analyses.detail(a.analysis()),beforeB=analyses.detail(b.analysis());
        try(var workers=java.util.concurrent.Executors.newFixedThreadPool(2)) {
            for(int round=0;round<3;round++) {
                var start=new java.util.concurrent.CyclicBarrier(2);
                String key="parallel-"+round;
                var left=workers.submit(()->previewAs(a,beforeA,warehouse,key,start));
                var right=workers.submit(()->previewAs(b,beforeB,warehouse,key,start));
                qty("1500",material(left.get(90,java.util.concurrent.TimeUnit.SECONDS),a.parentLine()).requiredQty());
                qty("1500",material(right.get(90,java.util.concurrent.TimeUnit.SECONDS),b.parentLine()).requiredQty());
            }
        }
        for(var pair:List.of(java.util.Map.entry(a,beforeA),java.util.Map.entry(b,beforeB))) {
            Tree t=pair.getKey();
            assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,t.analysis()));
            assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_material_analysis_plan_links WHERE analysis_id=?",Integer.class,t.analysis()));
            AnalysisView after=analyses.detail(t.analysis());
            assertEquals(pair.getValue().version(),after.version());assertEquals(pair.getValue().fingerprint(),after.fingerprint());
            qty("1000",material(after,t.parentLine()).requiredQty());
        }
    }

    private AnalysisView previewAs(Tree t,AnalysisView view,UUID warehouse,String key,java.util.concurrent.CyclicBarrier start) throws Exception {
        fixture.loginAs(t.world().superAdminUserId());
        try {
            start.await(30,java.util.concurrent.TimeUnit.SECONDS);
            return commands.previewIssuePlans(t.analysis(),new PreviewIssuePlansRequest(view.version(),view.fingerprint(),
                    "planned-issue-"+t.analysis()+"-"+key,warehouse,BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                    List.of(new IssueWorkshopPlansRequest.IssuePlanLine(t.rootLine(),new BigDecimal("1500"))),List.of()));
        } finally {
            org.springframework.security.core.context.SecurityContextHolder.clearContext();
        }
    }

    /**
     * 2026-09-21 用户口径「我修改下面某个层级的父件数量, 它的子层级也要对应地改」：
     * 层级表上任意一行填的数量都按计划产出量带动它自己的子层, 而它自己的需求量
     * 一个字节不动(那是祖先决定的)。预览整体回滚, 库里一行不留。
     */
    @Test void typedOutputOnAMiddleRowDrivesItsChildrenAndLeavesItselfAlone() {
        Tree t=seed("typed-middle");
        AnalysisView before=analyses.detail(t.analysis());
        qty("1000",material(before,t.parentLine()).requiredQty());qty("1000",material(before,t.childLine()).requiredQty());
        // 树顶不下达, 只把中间那个自制父件本批填成 1800。
        AnalysisView preview=commands.previewIssuePlans(t.analysis(),preview(before,t,"middle-1800",
                List.of(),List.of(typed(t.parentLine(),"1800"))));
        qty("1800",material(preview,t.childLine()).requiredQty());
        qty("1800",material(preview,t.childLine()).additionalSupplyRecommendedQty());
        // 填数量的那一行自己不受影响：需求仍是顶层给的 1000, 兄弟行也不动。
        qty("1000",material(preview,t.parentLine()).requiredQty());qty("1000",material(preview,t.buyLine()).requiredQty());
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,t.analysis()));
        AnalysisView after=analyses.detail(t.analysis());
        qty("1000",material(after,t.childLine()).requiredQty());
        assertEquals(before.version(),after.version());assertEquals(before.fingerprint(),after.fingerprint());
    }

    /** 树顶超量下达与中间层改量同时生效：顶层 1500 带大中间层, 中间层再按 1800 带大孙层。 */
    @Test void seedIssueAndTypedOutputsStackInOnePreview() {
        Tree t=seed("typed-stack");
        AnalysisView before=analyses.detail(t.analysis());
        AnalysisView preview=commands.previewIssuePlans(t.analysis(),preview(before,t,"stack",
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(t.rootLine(),new BigDecimal("1500"))),
                List.of(typed(t.parentLine(),"1800"))));
        qty("1500",material(preview,t.parentLine()).requiredQty());qty("1500",material(preview,t.buyLine()).requiredQty());
        qty("1800",material(preview,t.childLine()).requiredQty());
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_material_analysis_plan_links WHERE analysis_id=?",Integer.class,t.analysis()));
    }

    /**
     * 用户口径第三条：子件已经下过单的量要抵扣——父件还是 1000 时子件「还需安排 0」,
     * 父件改到 2000 时子件就只差 1000。
     */
    @Test void typedOutputNetsOutWhatTheChildAlreadyOrdered() {
        Tree t=seed("typed-ordered");
        AnalysisView view=analyses.detail(t.analysis());
        view=commands.notifySupply(t.analysis(),new NotifyRequest(view.version(),view.fingerprint(),
                "planned-notify-"+t.analysis()+"-child-1000","BUY",List.of(t.childLine()),List.of(),
                List.of(new SupplyQuantityInput(null,t.childLine(),new BigDecimal("1000"),BigDecimal.ZERO))));
        qty("1000",material(view,t.childLine()).requiredQty());
        qty("0",material(view,t.childLine()).additionalSupplyRecommendedQty());
        AnalysisView preview=commands.previewIssuePlans(t.analysis(),preview(view,t,"ordered-2000",
                List.of(),List.of(typed(t.parentLine(),"2000"))));
        qty("2000",material(preview,t.childLine()).requiredQty());
        qty("1000",material(preview,t.childLine()).additionalSupplyRecommendedQty());
        AnalysisView after=analyses.detail(t.analysis());
        qty("0",material(after,t.childLine()).additionalSupplyRecommendedQty());
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
        var surplus=commands.issueWorkshopPlans(t.analysis(),issue(anchored,t,"anchor-surplus",
                new IssueWorkshopPlansRequest.IssuePlanLine(null,anchor,new BigDecimal("200"),null,null,null,null,null,null,null,Boolean.TRUE)));
        // ADR-104：原计划没开工, 纯公共备货的 200 并进同一张——关联行 1000/200 同一行, 不另立。
        assertTrue(surplus.plans().getFirst().mergedIntoExisting());
        Object[] link=db.queryForObject("SELECT submitted_qty,public_surplus_qty FROM production_material_analysis_plan_links WHERE analysis_id=? AND analysis_item_id=? ORDER BY created_at DESC LIMIT 1",
                (rs,i)->new Object[]{rs.getBigDecimal(1),rs.getBigDecimal(2)},t.analysis(),anchor);
        qty("1000",(BigDecimal)link[0]);qty("200",(BigDecimal)link[1]);
        AnalysisView after=analyses.detail(t.analysis());
        // 锚点需求不变(仍 1000)，已下达计划量 1200；子件按锚点计划产出量 1200 展开。
        qty("1000",product(after,anchor).requestedQty());qty("1200",product(after,anchor).issuedPlanQty());
        qty("1200",material(after,t.parentLine()).plannedOutputQty());qty("1200",material(after,t.childLine()).requiredQty());
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,t.analysis()));
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

    /**
     * 销售订单来源的顶层(自制)按需求排满后再追加一批纯公共备货产出, 带「立即审核」。
     * 2026-09-22 用户实机: 主表顶层追加 1000 点下单, 审核里的销售分摊看到「归本需求量 0」就抛
     * 409「计划明细缺少可排产的销售需求量」——公共备货产出本来就不进订单侧, 不该要求分摊。
     */
    @Test void fullyPlannedSalesRootCanAppendAPureSurplusBatchWithApproveNow() {
        var w=fixture.seedWorld("planned-sales-surplus");
        UUID order=fixture.createApprovedOrder(w,w.goodsA(),"10","100");
        UUID orderItem=ReflectionTestUtils.invokeMethod(fixture,"orderItemId",order);
        fixture.loginAs(w.superAdminUserId());
        AnalysisView view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"planned-sales-preview-"+order,
                List.of(new PreviewItem("SALES_ORDER_ITEM",orderItem,null,null,null,null,null,BusinessTime.today().plusDays(10),new BigDecimal("10")))));
        UUID rootItem=view.products().getFirst().analysisLineId();
        ReflectionTestUtils.invokeMethod(fixture,"confirmRootMakeRoute",view.analysisId(),analyses.detail(view.analysisId()));
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","planned-sales-surplus");
        UUID workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId");
        UUID worker=ReflectionTestUtils.invokeMethod(assignment,"workerId");
        AnalysisView confirmed=analyses.detail(view.analysisId());
        // 先按需求 10 排满(立即审核)。
        commands.issueWorkshopPlans(view.analysisId(),new IssueWorkshopPlansRequest(confirmed.version(),confirmed.fingerprint(),
                "planned-sales-full-"+order,w.warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,rootItem,new BigDecimal("10"),null,null,workshop,null,worker,null,null))));
        AnalysisView planned=analyses.detail(view.analysisId());
        assertFalse(product(planned,rootItem).canSchedule());assertTrue(product(planned,rootItem).canIssueSurplus());
        qty("10",product(planned,rootItem).issuedPlanQty());
        BigDecimal plannedBefore=db.queryForObject("SELECT planned_qty FROM sales_order_items WHERE id=?",BigDecimal.class,orderItem);
        UUID fullPlan=db.queryForObject("SELECT plan_id FROM production_material_analysis_plan_links WHERE analysis_id=? AND analysis_item_id=?",UUID.class,view.analysisId(),rootItem);
        String approvedStatus=db.queryForObject("SELECT status FROM production_plans WHERE id=?",String.class,fullPlan);
        // 再追加 4: 纯公共备货 + 立即审核, 必须放行。ADR-104：第一张没开工, 并进同一张(10 归需求 + 4 公共)。
        var surplus=commands.issueWorkshopPlans(view.analysisId(),new IssueWorkshopPlansRequest(planned.version(),planned.fingerprint(),
                "planned-sales-surplus-"+order,w.warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,rootItem,new BigDecimal("4"),null,null,workshop,null,worker,null,null,Boolean.TRUE))));
        assertTrue(surplus.plans().getFirst().mergedIntoExisting());
        assertEquals(fullPlan,surplus.plans().getFirst().planId());
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,view.analysisId()));
        Object[] link=db.queryForObject("SELECT submitted_qty,public_surplus_qty FROM production_material_analysis_plan_links WHERE plan_id=?",
                (rs,i)->new Object[]{rs.getBigDecimal(1),rs.getBigDecimal(2)},fullPlan);
        qty("10",(BigDecimal)link[0]);qty("4",(BigDecimal)link[1]);
        qty("14",db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND is_deleted=FALSE",BigDecimal.class,fullPlan));
        // 审核态不变; 纯公共备货不进订单侧: 订单行 planned_qty 不动、排产关联容量仍是 10、新段没有销售分摊。
        assertEquals(approvedStatus,db.queryForObject("SELECT status FROM production_plans WHERE id=?",String.class,fullPlan));
        qty(plannedBefore.toPlainString(),db.queryForObject("SELECT planned_qty FROM sales_order_items WHERE id=?",BigDecimal.class,orderItem));
        qty("10",db.queryForObject("SELECT SUM(link.allocated_qty) FROM plan_order_item_links link JOIN production_plan_items item ON item.id=link.plan_item_id WHERE item.plan_id=? AND link.is_deleted=FALSE",
                BigDecimal.class,fullPlan));
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM production_execution_segments WHERE plan_id=? AND is_deleted=FALSE",Integer.class,fullPlan));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM execution_segment_sales_allocations allocation JOIN production_execution_segments segment ON segment.id=allocation.execution_segment_id WHERE segment.plan_id=? AND segment.segment_no=2",
                Integer.class,fullPlan));
        qty("14",product(analyses.detail(view.analysisId()),rootItem).issuedPlanQty());
    }

    /**
     * ADR-104(2026-09-22 用户口径「自制的追加, 生产车间没有去领料开工的前提下应该自动合并;
     * 已经开始执行了就创建新的单据」)：同一锚点第二次下达, 原计划已审核但车间没领料没开工 →
     * 并入原计划(同一单号、明细加量、关联行加量、计划包里多一段), 不另立新单。
     */
    @Test void appendingOnAnApprovedNotStartedPlanGrowsThatPlanInsteadOfCreatingAnother() {
        Tree t=seed("merge-append");
        AnalysisView before=analyses.detail(t.analysis());
        var first=commands.issueWorkshopPlans(t.analysis(),issue(before,t,"first-600",candidate(t.parentLine(),"600")));
        assertFalse(first.plans().getFirst().mergedIntoExisting());
        UUID planId=first.plans().getFirst().planId();
        AnalysisView anchored=analyses.detail(t.analysis());
        UUID anchor=material(anchored,t.parentLine()).planAnchorAnalysisLineId();
        qty("400",product(anchored,anchor).remainingQty());
        var request=issue(anchored,t,"second-400",candidate(t.parentLine(),"400"));
        var second=commands.issueWorkshopPlans(t.analysis(),request);
        assertEquals(1,second.plans().size());
        assertEquals(planId,second.plans().getFirst().planId());
        assertTrue(second.plans().getFirst().mergedIntoExisting());
        qty("400",second.plans().getFirst().appendedQty());
        assertEquals("APPROVED",second.plans().getFirst().status());
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,t.analysis()));
        qty("1000",db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND is_deleted=FALSE",BigDecimal.class,planId));
        Object[] link=db.queryForObject("SELECT submitted_qty,public_surplus_qty,allocation_status FROM production_material_analysis_plan_links WHERE plan_id=?",
                (rs,i)->new Object[]{rs.getBigDecimal(1),rs.getBigDecimal(2),rs.getString(3)},planId);
        qty("1000",(BigDecimal)link[0]);qty("0",(BigDecimal)link[1]);assertEquals("APPROVED",link[2]);
        // 计划包里两段(600 + 400): 原段一字不动, 新段 WAITING 且自带冻结的物料需求(子件 C 用量 1)。
        List<Object[]> segments=db.query("SELECT planned_qty,status,segment_no FROM production_execution_segments WHERE plan_id=? AND is_deleted=FALSE ORDER BY segment_no",
                (rs,i)->new Object[]{rs.getBigDecimal(1),rs.getString(2),rs.getInt(3)},planId);
        assertEquals(2,segments.size());
        qty("600",(BigDecimal)segments.get(0)[0]);qty("400",(BigDecimal)segments.get(1)[0]);
        assertEquals("WAITING",segments.get(1)[1]);assertEquals(2,segments.get(1)[2]);
        qty("400",db.queryForObject("SELECT SUM(demand.required_qty) FROM production_material_demands demand JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id WHERE segment.plan_id=? AND segment.segment_no=2 AND demand.is_deleted=FALSE",BigDecimal.class,planId));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_planning_packages WHERE plan_id=? AND status='CONFIRMED' AND is_deleted=FALSE",Integer.class,planId));
        AnalysisView after=analyses.detail(t.analysis());
        qty("1000",product(after,anchor).issuedPlanQty());qty("0",product(after,anchor).remainingQty());
        qty("1000",product(after,anchor).approvedQty());
        assertEquals(planId,product(after,anchor).latestPlanId());
        // 幂等重放: 同一把键回同一张计划、仍标记并入。
        var replay=commands.issueWorkshopPlans(t.analysis(),request);
        assertTrue(replay.replayed());assertEquals(planId,replay.plans().getFirst().planId());
        assertTrue(replay.plans().getFirst().mergedIntoExisting());
        // 排满后再追加 200 纯公共备货: 仍并入同一张, 关联行 1000/200, 三段; 子件需求按 1200 展开。
        var surplus=commands.issueWorkshopPlans(t.analysis(),issue(after,t,"surplus-200",
                new IssueWorkshopPlansRequest.IssuePlanLine(null,anchor,new BigDecimal("200"),null,null,null,null,null,null,null,Boolean.TRUE)));
        assertTrue(surplus.plans().getFirst().mergedIntoExisting());
        Object[] grown=db.queryForObject("SELECT submitted_qty,public_surplus_qty FROM production_material_analysis_plan_links WHERE plan_id=?",
                (rs,i)->new Object[]{rs.getBigDecimal(1),rs.getBigDecimal(2)},planId);
        qty("1000",(BigDecimal)grown[0]);qty("200",(BigDecimal)grown[1]);
        qty("1200",db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND is_deleted=FALSE",BigDecimal.class,planId));
        assertEquals(3,db.queryForObject("SELECT COUNT(*) FROM production_execution_segments WHERE plan_id=? AND is_deleted=FALSE",Integer.class,planId));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,t.analysis()));
        AnalysisView done=analyses.detail(t.analysis());
        qty("1200",product(done,anchor).issuedPlanQty());
        qty("1200",material(done,t.childLine()).requiredQty());
    }

    /** ADR-104：车间已经去领料(备料单已审核发料)的计划一字不动, 追加另立新单(用户口径「已经开始执行了就创建新的单据」)。 */
    @Test void appendingAfterTheWorkshopStartedProductionCreatesANewPlan() {
        Tree t=seed("merge-started");
        // 自制父件 P 只用采购件 C: 先把 C 备足, 第一批下达、确认齐套路线后就 READY 并带备料单。
        db.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES (?,?,5000)",t.world().warehouseId(),t.world().goodsC());
        AnalysisView before=analyses.detail(t.analysis());
        var first=commands.issueWorkshopPlans(t.analysis(),issue(before,t,"first-600",candidate(t.parentLine(),"600")));
        UUID planId=first.plans().getFirst().planId();
        fixture.confirmAllUnconfirmedFullKitRoutes();
        assertTrue(db.queryForObject("SELECT bool_and(status='READY') FROM production_execution_segments WHERE plan_id=? AND is_deleted=FALSE",Boolean.class,planId));
        // 车间申请领料、仓库审核发料 = 已经开始执行。
        List<UUID> draws=ReflectionTestUtils.invokeMethod(fixture,"currentPlanDrawIds",planId);
        assertFalse(draws.isEmpty(),"READY 段确认路线后应带备料单");
        fixture.requestWorkshopDraws("merge-started-"+planId,draws);
        var stockDocs=(com.uten.imp.features.stock.StockDocService)ReflectionTestUtils.getField(fixture,"stockDocService");
        fixture.loginAs(t.world().superAdminUserId());
        for(UUID draw:draws){
            com.uten.imp.features.stock.dto.StockDocIssueRequest issue=ReflectionTestUtils.invokeMethod(
                    fixture,"drawIssueRequest",draw,"merge-started-issue-"+draw,"ADR-104 已领料",null);
            stockDocs.approveAndIssue(draw,issue);
        }
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM stock_documents WHERE id IN (SELECT document_id FROM production_planning_package_documents WHERE document_type='DRAW' AND package_id IN (SELECT id FROM production_planning_packages WHERE plan_id=?)) AND status=0",Integer.class,planId));
        AnalysisView started=analyses.detail(t.analysis());
        UUID anchor=material(started,t.parentLine()).planAnchorAnalysisLineId();
        var second=commands.issueWorkshopPlans(t.analysis(),issue(started,t,"second-400",candidate(t.parentLine(),"400")));
        assertFalse(second.plans().getFirst().mergedIntoExisting());
        assertNotEquals(planId,second.plans().getFirst().planId());
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,t.analysis()));
        qty("600",db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND is_deleted=FALSE",BigDecimal.class,planId));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_execution_segments WHERE plan_id=? AND is_deleted=FALSE",Integer.class,planId));
        qty("1000",product(analyses.detail(t.analysis()),anchor).issuedPlanQty());
    }

    /**
     * ADR-104：草稿计划(没带「立即审核」)追加只并入草稿——同一张草稿加量、预排草案重排、仍待审核;
     * 之后带「立即审核」的追加把整张(含此前草稿量)一起审核落地。没带审核的追加不会并进已审核的计划。
     */
    @Test void appendingOnADraftPlanGrowsTheDraftAndALaterApprovedAppendApprovesItAsOne() {
        Tree t=seed("merge-draft");
        AnalysisView before=analyses.detail(t.analysis());
        var first=commands.issueWorkshopPlans(t.analysis(),new IssueWorkshopPlansRequest(before.version(),before.fingerprint(),
                "planned-issue-"+t.analysis()+"-draft-600",t.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),false,
                List.of(candidate(t.parentLine(),"600"))));
        UUID planId=first.plans().getFirst().planId();assertEquals("DRAFT",first.plans().getFirst().status());
        AnalysisView drafted=analyses.detail(t.analysis());
        UUID anchor=material(drafted,t.parentLine()).planAnchorAnalysisLineId();
        qty("600",product(drafted,anchor).submittedQty());
        var second=commands.issueWorkshopPlans(t.analysis(),new IssueWorkshopPlansRequest(drafted.version(),drafted.fingerprint(),
                "planned-issue-"+t.analysis()+"-draft-400",t.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),false,
                List.of(candidate(t.parentLine(),"400"))));
        assertEquals(planId,second.plans().getFirst().planId());assertTrue(second.plans().getFirst().mergedIntoExisting());
        assertEquals("DRAFT",second.plans().getFirst().status());
        qty("1000",db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND is_deleted=FALSE",BigDecimal.class,planId));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_planning_drafts WHERE plan_id=? AND status='ACTIVE'",Integer.class,planId));
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_planning_drafts WHERE plan_id=? AND status='SUPERSEDED'",Integer.class,planId));
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_planning_packages WHERE plan_id=? AND is_deleted=FALSE",Integer.class,planId));
        AnalysisView grown=analyses.detail(t.analysis());
        qty("1000",product(grown,anchor).submittedQty());qty("0",product(grown,anchor).approvedQty());
        // 带「立即审核」再追加 200 纯公共备货: 并入同一张草稿并整张审核——包按 1200 落地, 关联行 1000/200。
        var third=commands.issueWorkshopPlans(t.analysis(),issue(grown,t,"draft-approve-200",
                new IssueWorkshopPlansRequest.IssuePlanLine(null,anchor,new BigDecimal("200"),null,null,null,null,null,null,null,Boolean.TRUE)));
        assertEquals(planId,third.plans().getFirst().planId());assertTrue(third.plans().getFirst().mergedIntoExisting());
        assertEquals("APPROVED",third.plans().getFirst().status());
        qty("1200",db.queryForObject("SELECT SUM(planned_qty) FROM production_execution_segments WHERE plan_id=? AND is_deleted=FALSE",BigDecimal.class,planId));
        Object[] link=db.queryForObject("SELECT submitted_qty,public_surplus_qty,allocation_status FROM production_material_analysis_plan_links WHERE plan_id=?",
                (rs,i)->new Object[]{rs.getBigDecimal(1),rs.getBigDecimal(2),rs.getString(3)},planId);
        qty("1000",(BigDecimal)link[0]);qty("200",(BigDecimal)link[1]);assertEquals("APPROVED",link[2]);
        AnalysisView approved=analyses.detail(t.analysis());
        qty("1000",product(approved,anchor).approvedQty());qty("1200",product(approved,anchor).issuedPlanQty());
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,t.analysis()));
    }

    /**
     * ADR-104：销售来源的顶层追加归需求的量并入同一张已审核计划时, 订单侧同步扩容——
     * 排产关联容量与订单行 planned_qty 各加归需求份, 新段分摊到这份; 换车间追加 = 另一张单。
     */
    @Test void salesRootAppendGrowsThePlanItsOrderAllocationAndPlannedQtyUnlessTheWorkshopDiffers() {
        var w=fixture.seedWorld("planned-sales-merge");
        UUID order=fixture.createApprovedOrder(w,w.goodsA(),"10","100");
        UUID orderItem=ReflectionTestUtils.invokeMethod(fixture,"orderItemId",order);
        fixture.loginAs(w.superAdminUserId());
        AnalysisView view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"planned-sales-merge-preview-"+order,
                List.of(new PreviewItem("SALES_ORDER_ITEM",orderItem,null,null,null,null,null,BusinessTime.today().plusDays(10),new BigDecimal("10")))));
        UUID rootItem=view.products().getFirst().analysisLineId();
        ReflectionTestUtils.invokeMethod(fixture,"confirmRootMakeRoute",view.analysisId(),analyses.detail(view.analysisId()));
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","planned-sales-merge");
        UUID workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId");
        UUID worker=ReflectionTestUtils.invokeMethod(assignment,"workerId");
        AnalysisView confirmed=analyses.detail(view.analysisId());
        var first=commands.issueWorkshopPlans(view.analysisId(),new IssueWorkshopPlansRequest(confirmed.version(),confirmed.fingerprint(),
                "planned-sales-merge-6-"+order,w.warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,rootItem,new BigDecimal("6"),null,null,workshop,null,worker,null,null))));
        UUID planId=first.plans().getFirst().planId();
        UUID planItem=db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=? AND is_deleted=FALSE",UUID.class,planId);
        qty("6",db.queryForObject("SELECT planned_qty FROM sales_order_items WHERE id=?",BigDecimal.class,orderItem));
        AnalysisView planned=analyses.detail(view.analysisId());
        var second=commands.issueWorkshopPlans(view.analysisId(),new IssueWorkshopPlansRequest(planned.version(),planned.fingerprint(),
                "planned-sales-merge-4-"+order,w.warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,rootItem,new BigDecimal("4"),null,null,workshop,null,worker,null,null))));
        assertEquals(planId,second.plans().getFirst().planId());assertTrue(second.plans().getFirst().mergedIntoExisting());
        qty("10",db.queryForObject("SELECT allocated_qty FROM plan_order_item_links WHERE plan_item_id=? AND is_deleted=FALSE",BigDecimal.class,planItem));
        qty("10",db.queryForObject("SELECT planned_qty FROM sales_order_items WHERE id=?",BigDecimal.class,orderItem));
        qty("4",db.queryForObject("SELECT allocation.allocated_qty FROM execution_segment_sales_allocations allocation JOIN production_execution_segments segment ON segment.id=allocation.execution_segment_id WHERE segment.plan_id=? AND segment.segment_no=2",BigDecimal.class,planId));
        qty("10",product(analyses.detail(view.analysisId()),rootItem).approvedQty());
        // 换一个车间追加 2(纯公共备货): 车间不同 = 另一张单。
        Object other=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","planned-sales-merge-other");
        UUID otherWorkshop=ReflectionTestUtils.invokeMethod(other,"workshopId");
        UUID otherWorker=ReflectionTestUtils.invokeMethod(other,"workerId");
        AnalysisView full=analyses.detail(view.analysisId());
        var third=commands.issueWorkshopPlans(view.analysisId(),new IssueWorkshopPlansRequest(full.version(),full.fingerprint(),
                "planned-sales-merge-other-"+order,w.warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,rootItem,new BigDecimal("2"),null,null,otherWorkshop,null,otherWorker,null,null,Boolean.TRUE))));
        assertFalse(third.plans().getFirst().mergedIntoExisting());assertNotEquals(planId,third.plans().getFirst().planId());
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,view.analysisId()));
        qty("10",db.queryForObject("SELECT planned_qty FROM sales_order_items WHERE id=?",BigDecimal.class,orderItem));
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
        // ADR-104：前置自制那张计划没开工, 追加并进同一张——关联行 1000/200 同一行。
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=?",Integer.class,t.analysis()));
        Object[] link=db.queryForObject("SELECT submitted_qty,public_surplus_qty FROM production_material_analysis_plan_links WHERE analysis_id=? AND analysis_item_id=? ORDER BY created_at DESC LIMIT 1",
                (rs,i)->new Object[]{rs.getBigDecimal(1),rs.getBigDecimal(2)},t.analysis(),anchor);
        qty("1000",(BigDecimal)link[0]);qty("200",(BigDecimal)link[1]);
    }

    private static IssueWorkshopPlansRequest.IssuePlanLine candidate(UUID material,String qty) {
        return new IssueWorkshopPlansRequest.IssuePlanLine(material,null,new BigDecimal(qty),null,null,null,null,null,null,null);
    }
    private static IssueWorkshopPlansRequest issue(AnalysisView view,Tree t,String key,IssueWorkshopPlansRequest.IssuePlanLine... lines) {
        return new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),"planned-issue-"+t.analysis()+"-"+key,t.world().warehouseId(),
                BusinessTime.today(),BusinessTime.today().plusDays(10),true,List.of(lines));
    }
    /**
     * 2026-09-21 用户口径「假如没有下单, 立马把父件改回 1000, 子件也要立马变回 1000」：
     * 把来源数量调高再调回来, 自制锚点的配额要跟着回落——只退**从来没下达过**的那部分,
     * 已提交/已审核的计划一分不动。不退的话锚点永久停在高位, 子件那一行的「还需安排」
     * 再也降不下来。
     */
    @Test void makeAnchorQuotaFollowsSourceDemandBackDownWhenNothingWasIssued() {
        Tree t=seed("anchor-shrink");
        AnalysisView before=analyses.detail(t.analysis());
        commands.issueWorkshopPlans(t.analysis(),issue(before,t,"parent-anchor",candidate(t.parentLine(),"1000")));
        AnalysisView anchored=analyses.detail(t.analysis());
        UUID anchor=material(anchored,t.parentLine()).planAnchorAnalysisLineId();
        assertNotNull(anchor);qty("1000",product(anchored,anchor).requestedQty());
        // 来源数量 1000 → 2000: 锚点配额跟着涨到 2000。
        AnalysisView raised=refreshSource(t,"2000","up1");
        qty("2000",material(raised,t.parentLine()).requiredQty());
        qty("2000",product(raised,anchor).requestedQty());
        qty("1000",product(raised,anchor).remainingQty());
        // 一张计划都没下就把来源改回 1000: 配额退回 1000, 子件行的「还需安排」跟着回落。
        AnalysisView back=refreshSource(t,"1000","down1");
        qty("1000",material(back,t.parentLine()).requiredQty());
        qty("1000",product(back,anchor).requestedQty());
        qty("0",product(back,anchor).remainingQty());
        qty("1000",material(back,t.childLine()).requiredQty());
        // 已下达的那部分退不掉: 涨到 2000 后真排 1500, 再改回 1000 只退到 1500。
        AnalysisView again=refreshSource(t,"2000","up2");
        commands.issueWorkshopPlans(t.analysis(),new IssueWorkshopPlansRequest(again.version(),again.fingerprint(),
                "planned-issue-"+t.analysis()+"-anchor-500",t.world().warehouseId(),
                BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(anchor,new BigDecimal("500")))));
        AnalysisView issued=analyses.detail(t.analysis());
        qty("2000",product(issued,anchor).requestedQty());
        AnalysisView floored=refreshSource(t,"1000","down2");
        qty("1500",product(floored,anchor).requestedQty());
        qty("0",product(floored,anchor).remainingQty());
    }

    /** 按新数量重跑一次来源预览(与页面上改数量后刷新同一条路径, 会提交)。 */
    private AnalysisView refreshSource(Tree t,String qty,String tag) {
        AnalysisView current=analyses.detail(t.analysis());
        return analyses.preview(new PreviewRequest(t.analysis(),current.version(),current.fingerprint(),
                t.world().warehouseId(),"planned-resource-"+t.analysis()+"-"+tag,
                List.of(new PreviewItem("OTHER",null,t.root(),null,t.world().unitId(),
                        "planned-source-anchor-shrink-"+t.root(),"计划量单一入口",
                        BusinessTime.today().plusDays(10),new BigDecimal(qty)))));
    }

    /**
     * 2026-09-21 用户口径「采购能超量下, 委外和车间也要能」(V641)：我方供料、只有一颗
     * 叶子子件的委外件(ADR-085 直接外发)可以超量下达, 服务端按「归需求量 + 公共备货」
     * 分账并合成一条申请明细; 多下的那部分在层级表上按计划产出量如实带大子件需求。
     */
    @Test void soleComponentSubcontractTakesOverQuantityAndItsComponentFollows() {
        var w=fixture.seedWorld("planned-sole-surplus");fixture.loginAs(w.superAdminUserId());
        UUID root=UUID.randomUUID(),sub=UUID.randomUUID();
        fixture.insertGoods(root,"PQL-ROOT-"+root,"单一子件委外成品","自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(sub,"PQL-S-"+sub,"我方供料委外件","委外",w.unitId(),w.unitLegacy());
        // 委外件正好一颗子件 = ADR-085 直接外发形态(我方发那颗子件给委外商)。
        fixture.insertBom(root,sub,"1");fixture.insertBom(sub,w.goodsC(),"1");
        db.update("UPDATE goods SET default_supplier_id=? WHERE id=?",w.supplierId(),w.goodsC());
        db.update("UPDATE goods SET default_supplier_id=? WHERE id=?",w.supplierId(),sub);
        AnalysisView view=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"planned-sole-preview-"+root,
                List.of(new PreviewItem("OTHER",null,root,null,w.unitId(),"planned-sole-source-"+root,"单一子件委外",BusinessTime.today().plusDays(10),new BigDecimal("1000")))));
        view=analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"planned-sole-routes-"+view.analysisId(),
                view.flatMaterials().stream().filter(MaterialView::actionable)
                        .map(m->new RouteDecision(m.materialLineId(),m.actionGroupKey(),
                                m.goodsId().equals(sub)?"SUBCONTRACT":m.goodsId().equals(root)?"MAKE":"BUY",null)).toList()));
        UUID analysis=view.analysisId(),subLine=line(view,sub),componentLine=line(view,w.goodsC());
        qty("1000",material(view,subLine).requiredQty());qty("1000",material(view,componentLine).requiredQty());
        // 层级表上把委外件填成 1500：我方供料的那颗子件按 1500 备(预览整体回滚)。
        AnalysisView preview=commands.previewIssuePlans(analysis,new PreviewIssuePlansRequest(
                view.version(),view.fingerprint(),"planned-sole-preview-cascade-"+analysis,w.warehouseId(),
                BusinessTime.today(),BusinessTime.today().plusDays(10),false,List.of(),
                List.of(new PreviewIssuePlansRequest.TypedOutput(subLine,new BigDecimal("1500")))));
        qty("1500",material(preview,componentLine).requiredQty());
        qty("1500",material(preview,componentLine).additionalSupplyRecommendedQty());
        qty("1000",material(preview,subLine).requiredQty());
        // 真的按 1500 下达委外：V641 之前这里被「我方供料的委外件不能创建公共超量备货」拒绝。
        AnalysisView notified=commands.notifySupply(analysis,new NotifyRequest(view.version(),view.fingerprint(),
                "planned-sole-notify-"+analysis,"SUBCONTRACT",List.of(subLine),List.of(),
                List.of(new SupplyQuantityInput(null,subLine,new BigDecimal("1500"),BigDecimal.ZERO))));
        Object[] action=db.queryForObject("""
                SELECT requested_qty,public_surplus_qty FROM preplan_supply_actions
                WHERE analysis_id=? AND route='SUBCONTRACT' AND operation_type='SUPPLY'
                """,(rs,i)->new Object[]{rs.getBigDecimal(1),rs.getBigDecimal(2)},analysis);
        qty("1000",(BigDecimal)action[0]);qty("500",(BigDecimal)action[1]);
        // 需求片与公共片合成同一条委外申请明细(V588 形态)。
        qty("1500",db.queryForObject("""
                SELECT item.qty FROM subcontract_application_items item
                JOIN preplan_supply_actions action ON action.public_surplus_external_item_id=item.id
                WHERE action.analysis_id=?
                """,BigDecimal.class,analysis));
        assertNotNull(material(notified,componentLine));
    }

    private static PreviewIssuePlansRequest previewOf(IssueWorkshopPlansRequest request) {
        return new PreviewIssuePlansRequest(request.version(),request.fingerprint(),request.idempotencyKey(),request.warehouseId(),
                request.billDate(),request.deliveryDate(),request.approveNow(),request.lines(),List.of());
    }
    private static PreviewIssuePlansRequest.TypedOutput typed(UUID materialLine,String qty) {
        return new PreviewIssuePlansRequest.TypedOutput(materialLine,new BigDecimal(qty));
    }
    private static PreviewIssuePlansRequest preview(AnalysisView view,Tree t,String key,
            List<IssueWorkshopPlansRequest.IssuePlanLine> lines,List<PreviewIssuePlansRequest.TypedOutput> typed) {
        return new PreviewIssuePlansRequest(view.version(),view.fingerprint(),"planned-preview-"+t.analysis()+"-"+key,
                t.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,lines,typed);
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
