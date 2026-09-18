package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.directtransfer.ProductionWorkshopDirectTransferService;
import com.uten.imp.features.production.execution.ProductionDrawRequest;
import com.uten.imp.features.production.execution.ProductionDrawRequestService;
import com.uten.imp.features.production.execution.ProductionExecutionSegmentService;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.StockQueryService;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.IssueWorkshopPlansRequest;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteDecision;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteRequest;
import static org.junit.jupiter.api.Assertions.*;

/**
 * 车间直送 v2(V595 / ADR-089)的用户口径回归：
 *
 * <ol>
 *   <li>「部分开工 · 持续生产」：子件全由同车间直送时一键开工，线边仓由系统自动配置；
 *       之后每一笔直送审核自动补投，报工量以已到料折算封顶，最后一次报工后余量释放；</li>
 *   <li>混合链：仓库物料缺时开不了工(报出缺什么)，领齐仓库料才开工，直送子件照旧分次到料；</li>
 *   <li>线边仓里的直送料只归指名的父件，别的任务看不见、拿不走；</li>
 *   <li>报工页候选带上次的去向与父件产品记忆。</li>
 * </ol>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only", "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class WorkshopContinuousSupplyEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionExecutionSegmentService segments;
    @Autowired ProductionDailyReportService reports;
    @Autowired ProductionWorkshopDirectTransferService directTransfers;
    @Autowired ProductionDrawRequestService drawRequests;
    @Autowired StockDocService stock;
    @Autowired StockQueryService stockQuery;
    FullChainEndToEndTest fixture;

    @BeforeEach
    void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void logout() {
        org.springframework.security.core.context.SecurityContextHolder.clearContext();
    }

    @Test
    void allDirectChildrenStartAtOnceAndEachTransferTopsUpTheRunningParent() {
        Case c = create("cs-all", false);
        // 线边仓不预建：第一笔直送时由系统按「车间 × 主仓」自动配置。
        assertEquals(0, lineSideCount(c.workshop()));
        fixture.loginAs(c.workerUser());
        // V599：先确认「持续生产」路线，才能按持续生产开工。
        confirmRoute(c.plan(), c.segment(), "CONTINUOUS");
        // 用户口径(2026-09-17)：一件料都没到不是「部分开工」，是空开工——不许开，也不许去领料。
        assertEquals(Boolean.FALSE, db.queryForObject(
                "SELECT fn_can_start_continuous_supply(?)", Boolean.class, c.segment()),
                "料架空着的工单不能按持续生产开工");
        ApiException empty = assertThrows(ApiException.class, () -> segments.startContinuousSupply(
                c.plan(), c.segment(),
                new SegmentTransitionRequest(version(c.segment()), "cs-all-empty-" + c.segment())));
        assertTrue(empty.getMessage().contains("一件都还没到"), empty.getMessage());
        assertEquals("WAITING", status(c.segment()));
        assertEquals(Boolean.FALSE, db.queryForObject(
                "SELECT continuous_supply FROM production_execution_segments WHERE id=?", Boolean.class, c.segment()),
                "被拒的开工不留半个持续生产标记");

        // 子件先报工直送 40 套：料落进自动配置的线边仓，父件仍在等待物料。
        var waitingListing = directTransfers.candidates(c.childSegment(), c.child(), null);
        assertEquals(1, waitingListing.candidates().size());
        assertEquals("WAITING", waitingListing.candidates().getFirst().executionSegmentStatus());
        transfer(c, "40", false);
        UUID lineSide = db.queryForObject("""
                SELECT id FROM warehouses WHERE is_line_side AND workshop_department_id=? AND NOT is_deleted
                """, UUID.class, c.workshop());
        assertEquals(Boolean.TRUE, db.queryForObject("SELECT auto_created FROM warehouses WHERE id=?", Boolean.class, lineSide),
                "线边仓由系统自动配置");
        assertEquals(c.world().warehouseId(), db.queryForObject("SELECT parent_id FROM warehouses WHERE id=?", UUID.class, lineSide),
                "线边仓挂在收料主仓下(同主仓分仓领料前提)");
        qty("40", balance(lineSide, c.child()));

        // 每种子件都到了一部分，这才是「部分开工」：开工即把料架上的 40 投进去。
        fixture.loginAs(c.workerUser());
        assertEquals(Boolean.TRUE, db.queryForObject(
                "SELECT fn_can_start_continuous_supply(?)", Boolean.class, c.segment()),
                "每种直送子件都到了一部分：可以按持续生产开工");
        var started = segments.startContinuousSupply(c.plan(), c.segment(),
                new SegmentTransitionRequest(version(c.segment()), "cs-all-start-" + c.segment()));
        assertEquals("IN_PROGRESS", started.status(), "没有任何仓库物料要等：一键即开工");
        assertTrue(started.continuousSupply());
        assertEquals(Boolean.TRUE, db.queryForObject(
                "SELECT direct_supply FROM production_material_demands WHERE id=?", Boolean.class, parentDemand(c)));
        qty("40", reserved(parentDemand(c)));
        qty("40", issued(parentDemand(c)));
        qty("0", balance(lineSide, c.child()));

        // 全直送工单没有任何要仓库发的料：领料汇总直接拒绝，不再「零行提交成功」。
        ApiException noWarehouseMaterial = assertThrows(ApiException.class,
                () -> drawRequests.preview(new ProductionDrawRequest.PreviewRequest(
                        List.of(new ProductionDrawRequest.Item(c.segment(), version(c.segment()))))));
        assertTrue(noWarehouseMaterial.getMessage().contains("不需要仓库发料")
                        || noWarehouseMaterial.getMessage().contains("没有需要仓库发料")
                        || noWarehouseMaterial.getMessage().contains("仅物料齐套"),
                noWarehouseMaterial.getMessage());

        // 第二笔直送 60 继续补投：候选里能看到正在持续生产的父件。
        var listing = directTransfers.candidates(c.childSegment(), c.child(), null);
        assertEquals(1, listing.candidates().size());
        assertTrue(listing.candidates().getFirst().continuousSupply());
        assertEquals("IN_PROGRESS", listing.candidates().getFirst().executionSegmentStatus());
        assertEquals("IN_PROGRESS", status(c.segment()), "补投不改变工单状态");

        // 父件报工：只到 40 套子件就只能报 40 个。
        assertEquals(0, new BigDecimal("40").compareTo(maxReportQty(c)));
        reportParent(c, "30", false);
        ApiException over = assertThrows(ApiException.class, () -> reportParent(c, "20", false));
        assertTrue(over.getMessage().contains("最多可报"), over.getMessage());

        // 后续直送 60 → 上限 100，最后一次报工 70 完结。
        transfer(c, "60", false);
        qty("100", issued(parentDemand(c)));
        reportParent(c, "70", true);
        assertEquals("FULFILLED", db.queryForObject(
                "SELECT status FROM production_material_demands WHERE id=?", String.class, parentDemand(c)));
        // 线边仓料只是路过料架：进多少出多少。
        qty("0", balance(lineSide, c.child()));
        // 线边仓不进即时库存(默认口径)，显式打开才看得见。
        assertTrue(stockQuery.instantInventory(null, null, true, null, 1, 50, null, null).getItems().stream()
                .noneMatch(row -> c.child().equals(row.getGoodsId())
                        && row.getQty() != null && row.getQty().signum() > 0),
                "即时库存默认剔除线边仓");
    }

    @Test
    void mixedChainNeedsWarehousePartFirstThenDirectPartFlowsIn() {
        Case c = create("cs-mixed", true);
        fixture.loginAs(c.workerUser());
        // V599：混合链同样先确认「持续生产」路线。
        confirmRoute(c.plan(), c.segment(), "CONTINUOUS");
        // 两道前提各说各的话：先是直送子件一件没到，再是仓库子件没入库。
        ApiException emptyRack = assertThrows(ApiException.class, () -> segments.startContinuousSupply(
                c.plan(), c.segment(),
                new SegmentTransitionRequest(version(c.segment()), "cs-mixed-empty-" + c.segment())));
        assertTrue(emptyRack.getMessage().contains("一件都还没到"), emptyRack.getMessage());

        transfer(c, "50", false);
        fixture.loginAs(c.workerUser());
        ApiException shortage = assertThrows(ApiException.class, () -> segments.startContinuousSupply(
                c.plan(), c.segment(),
                new SegmentTransitionRequest(version(c.segment()), "cs-mixed-early-" + c.segment())));
        assertTrue(shortage.getMessage().contains("缺"), "仓库物料没到要说清缺什么: " + shortage.getMessage());
        assertEquals("WAITING", status(c.segment()));
        assertEquals(Boolean.FALSE, db.queryForObject(
                "SELECT continuous_supply FROM production_execution_segments WHERE id=?", Boolean.class, c.segment()),
                "开工失败整单回滚，不留半个持续生产标记");

        receive(c, c.secondMaterial(), c.leaf(), "100");
        fixture.loginAs(c.workerUser());
        var ready = segments.startContinuousSupply(c.plan(), c.segment(),
                new SegmentTransitionRequest(version(c.segment()), "cs-mixed-start-" + c.segment()));
        assertEquals("READY", ready.status(), "仓库物料要先领齐，停在齐套待领料");
        assertTrue(ready.continuousSupply());
        // 领料汇总只剩仓库子件(直送子件不出现)。
        var items = List.of(new ProductionDrawRequest.Item(c.segment(), version(c.segment())));
        var preview = drawRequests.preview(new ProductionDrawRequest.PreviewRequest(items));
        assertEquals(1, preview.lines().size());
        assertEquals(c.secondMaterial(), preview.lines().getFirst().goodsId());
        var submitted = drawRequests.submit(new ProductionDrawRequest.SubmitRequest(
                items, "cs-mixed-request-" + c.segment(), preview.fingerprint()));
        fixture.loginAs(c.world().superAdminUserId());
        var issue = new StockDocIssueBatchRequest();
        issue.setIdempotencyKey("cs-mixed-issue-" + c.segment());
        issue.setDocIds(submitted.documentIds());
        stock.issueFullBatch(issue);
        fixture.loginAs(c.workerUser());
        var started = segments.start(c.plan(), c.segment(),
                new SegmentTransitionRequest(version(c.segment()), "cs-mixed-go-" + c.segment()));
        assertEquals("IN_PROGRESS", started.status());
        // 开工那一刻料架上的 50 已经投进去了：报工上限就是 50，多报一个都不行。
        qty("50", issued(parentDemand(c)));
        assertEquals(0, new BigDecimal("50").compareTo(maxReportQty(c)));
        reportParent(c, "50", false);

        // 后续直送继续补投，上限随之抬到 100。
        transfer(c, "50", false);
        qty("100", issued(parentDemand(c)));
        assertEquals(0, new BigDecimal("50").compareTo(maxReportQty(c)), "已报 50，还能再报 50");
    }

    @Test
    void lineSideStockBelongsOnlyToTheTargetedParent() {
        Case c = create("cs-scope", true);
        // 同车间再来一张同产品工单 P2(只需要子件 B，等待物料)。
        UUID otherOrder = fixture.createApprovedOrder(c.world(), c.parent(), "100", "100");
        UUID otherOrderItem = db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?", UUID.class, otherOrder);
        fixture.loginAs(c.world().superAdminUserId());
        var view = analyses.preview(new PreviewRequest(null, null, null, c.world().warehouseId(),
                "preview-scope-2", List.of(new PreviewItem("SALES_ORDER_ITEM", otherOrderItem,
                null, null, null, null, null, BusinessTime.today().plusDays(10), new BigDecimal("100")))));
        analyses.saveRoutes(view.analysisId(), new RouteRequest(view.version(), view.fingerprint(),
                "routes-scope-2", view.flatMaterials().stream()
                        .map(row -> new RouteDecision(row.materialLineId(), row.actionGroupKey(),
                                row.goodsId().equals(c.parent()) || row.goodsId().equals(c.child()) ? "MAKE" : "BUY", null))
                        .toList()));
        view = analyses.detail(view.analysisId());
        var second = commands.issueWorkshopPlans(view.analysisId(), new IssueWorkshopPlansRequest(
                view.version(), view.fingerprint(), "root-scope-2", c.world().warehouseId(),
                BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                        null, view.products().getFirst().analysisLineId(), new BigDecimal("100"),
                        BusinessTime.today(), BusinessTime.today().plusDays(10),
                        c.workshop(), null, c.worker(), null, null))));
        UUID secondPlan = second.plans().getFirst().planId();
        UUID secondSegment = db.queryForObject(
                "SELECT id FROM production_execution_segments WHERE plan_id=? AND status='WAITING'", UUID.class, secondPlan);

        // 子件 100 直送给 P1(P1 还缺仓库料，料先留在线边仓)。
        transfer(c, "100", false);
        UUID lineSide = db.queryForObject(
                "SELECT id FROM warehouses WHERE is_line_side AND workshop_department_id=? AND NOT is_deleted", UUID.class, c.workshop());
        qty("100", balance(lineSide, c.child()));
        assertEquals("WAITING", status(c.segment()));
        // P2 只差子件 B，但线边仓里那 100 个是 P1 的：重核后仍等待物料，一件都不许拿。
        fixture.loginAs(c.workerUser());
        // V599：P2 重核前先确认齐套路线（重核=齐套提升，受路线门控）。
        confirmRoute(secondPlan, secondSegment, "FULL_KIT");
        ApiException blocked = assertThrows(ApiException.class, () -> segments.recheckMaterial(secondPlan, secondSegment,
                new SegmentTransitionRequest(version(secondSegment), "cs-scope-recheck-" + secondSegment)));
        assertTrue(blocked.getMessage().contains("缺料"), blocked.getMessage());
        assertEquals("WAITING", status(secondSegment));
        assertEquals(0, db.queryForObject("""
                SELECT count(*) FROM stock_reservations r JOIN production_material_demands d ON d.id=r.demand_id
                WHERE d.execution_segment_id=? AND NOT r.is_deleted
                """, Integer.class, secondSegment));

        // 仓库料到了以后 P1 确认齐套路线：确认那一刻同事务补跑提升(线边仓的 100 归它，
        // 自动出库，不需要任何领料申请)——V599 起这不再需要单独点一次重核。
        receive(c, c.secondMaterial(), c.leaf(), "100");
        fixture.loginAs(c.workerUser());
        var promoted = segments.confirmRoute(c.plan(), c.segment(),
                new com.uten.imp.features.production.execution.SegmentRouteConfirmRequest(
                        version(c.segment()), "cs-scope-confirm-" + c.segment(), "FULL_KIT"));
        assertEquals("READY", promoted.status());
        qty("100", issued(parentDemand(c)));
        qty("0", balance(lineSide, c.child()));
        var preview = drawRequests.preview(new ProductionDrawRequest.PreviewRequest(
                List.of(new ProductionDrawRequest.Item(c.segment(), version(c.segment())))));
        assertEquals(1, preview.lines().size(), "领料汇总只剩仓库子件");
        assertEquals(c.secondMaterial(), preview.lines().getFirst().goodsId());
    }

    @Test
    void candidatesRememberTheLastDestinationAndReceivingProduct() {
        Case c = create("cs-memory", false);
        fixture.loginAs(c.workerUser());
        var before = directTransfers.candidates(c.childSegment(), c.child(), null);
        assertNull(before.lastDestination(), "从没报过：没有记忆");
        transfer(c, "10", false);
        var after = directTransfers.candidates(c.childSegment(), c.child(), null);
        assertEquals("WORKSHOP", after.lastDestination());
        assertEquals(c.parent(), after.lastReceivingGoodsId(), "记住的是父件产品，不是工单号");
        assertEquals(1, after.candidates().size());
        assertEquals(0, new BigDecimal("90").compareTo(after.candidates().getFirst().remainingQty()),
                "还差多少 = 需求量 − 已直送/已预留");
    }

    /**
     * 子件先直送、父件后按持续生产开工：线边仓里已到的料在开工那一刻就得预留出库
     * (分析权益转正 → 线边仓领料单 → 同事务出库)，不用任何人再点领料；之后的直送照旧补投。
     */
    @Test
    void directPartAlreadyOnTheRackIsIssuedWhenContinuousStartHappensLater() {
        Case c = create("cs-late", false);
        // 父件还是普通等待物料工单：30 个子件直送后仍不齐套，料留在线边仓。
        transfer(c, "30", false);
        UUID lineSide = db.queryForObject(
                "SELECT id FROM warehouses WHERE is_line_side AND workshop_department_id=? AND NOT is_deleted", UUID.class, c.workshop());
        qty("30", balance(lineSide, c.child()));
        qty("0", reserved(parentDemand(c)));
        assertEquals("WAITING", status(c.segment()));
        assertEquals(Boolean.TRUE, db.queryForObject(
                "SELECT fn_can_start_continuous_supply(?)", Boolean.class, c.segment()),
                "料只是躺在线边仓，工单本身没被动过，仍可按持续生产开工");

        fixture.loginAs(c.workerUser());
        // V599：直送料已在线边仓、工单未被动过——先确认持续生产路线再开工。
        confirmRoute(c.plan(), c.segment(), "CONTINUOUS");
        var started = segments.startContinuousSupply(c.plan(), c.segment(),
                new SegmentTransitionRequest(version(c.segment()), "cs-late-start-" + c.segment()));
        assertEquals("IN_PROGRESS", started.status(), "没有仓库物料要等：一键即开工");
        qty("30", reserved(parentDemand(c)));
        qty("30", issued(parentDemand(c)));
        qty("0", balance(lineSide, c.child()));
        assertEquals(0, new BigDecimal("30").compareTo(maxReportQty(c)), "开工时就把线边仓已到的 30 投进去了");

        // 之后的直送继续逐笔补投，同一需求另起一行正式预留(上一行已出库消耗)。
        transfer(c, "20", false);
        qty("50", issued(parentDemand(c)));
        assertEquals(2, db.queryForObject("""
                SELECT count(*) FROM stock_reservations r
                WHERE r.demand_id=? AND NOT r.is_deleted AND r.owner_type='PRODUCTION_MATERIAL_DEMAND'
                """, Integer.class, parentDemand(c)));
    }

    // ===================== 夹具 =====================

    private record Case(
            FullChainEndToEndTest.World world,
            UUID parent, UUID child, UUID secondMaterial,
            UUID plan, UUID segment,
            UUID childPlan, UUID childSegment,
            UUID workshop, UUID worker, UUID workerUser,
            UUID leaf, UUID planItem) {
    }

    /** 父件(自制) → 子件(自制叶子，零料直制)；可选第二种采购子件。主仓下挂普通叶子子仓，**不**预建线边仓。 */
    private Case create(String tag, boolean withBuyMaterial) {
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID parent = UUID.randomUUID(), child = UUID.randomUUID();
        UUID secondMaterial = withBuyMaterial ? UUID.randomUUID() : null;
        fixture.insertGoods(parent, "P-" + tag, "持续父件-" + tag, "自制", w.unitId(), w.unitLegacy());
        fixture.insertGoods(child, "CL-" + tag, "持续子件-" + tag, "自制", w.unitId(), w.unitLegacy());
        fixture.insertBom(parent, child, "1");
        if (withBuyMaterial) {
            fixture.insertGoods(secondMaterial, "MAT-" + tag, "仓库子件-" + tag, "采购", w.unitId(), w.unitLegacy());
            fixture.insertBom(parent, secondMaterial, "1");
        }
        UUID production = db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD'", UUID.class);
        UUID workshop = UUID.randomUUID(), worker = UUID.randomUUID();
        db.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES(?,?,?,?,'二级班组')",
                workshop, "W-" + tag, "持续车间-" + tag, production);
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')
                """, worker, "CS-WORKER-" + tag, "持续负责人-" + tag, workshop);
        UUID workerUser = fixture.createUserWithPerms(w, "cs-worker-" + tag,
                "production_execution:view", "production_execution:start",
                "production_daily_report:view", "production_daily_report:create",
                "production_daily_report:approve", "production_direct_transfer:approve",
                "production_material:settle");
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",
                workshop, workerUser);
        UUID leaf = UUID.randomUUID();
        db.update("""
                INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable)
                VALUES(?,?,?,?,'使用',TRUE)
                """, leaf, "SUB-" + tag, "普通子仓-" + tag, w.warehouseId());
        fixture.loginAs(w.superAdminUserId());

        UUID order = fixture.createApprovedOrder(w, parent, "100", "100");
        UUID orderItem = db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?", UUID.class, order);
        var view = analyses.preview(new PreviewRequest(null, null, null, w.warehouseId(),
                "preview-" + tag, List.of(new PreviewItem("SALES_ORDER_ITEM", orderItem,
                null, null, null, null, null, BusinessTime.today().plusDays(10), new BigDecimal("100")))));
        analyses.saveRoutes(view.analysisId(), new RouteRequest(view.version(), view.fingerprint(),
                "routes-" + tag, view.flatMaterials().stream()
                        .map(row -> new RouteDecision(row.materialLineId(), row.actionGroupKey(),
                                row.goodsId().equals(parent) || row.goodsId().equals(child) ? "MAKE" : "BUY", null))
                        .toList()));
        view = analyses.detail(view.analysisId());
        UUID childLineId = view.flatMaterials().stream()
                .filter(row -> row.goodsId().equals(child)).findFirst().orElseThrow().materialLineId();
        var childResult = commands.issueWorkshopPlans(view.analysisId(), new IssueWorkshopPlansRequest(
                view.version(), view.fingerprint(), "child-" + tag, w.warehouseId(),
                BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                        childLineId, null, new BigDecimal("100"),
                        BusinessTime.today(), BusinessTime.today().plusDays(10),
                        workshop, null, worker, null, null))));
        UUID childPlan = childResult.plans().getFirst().planId();
        UUID childSegment = childResult.plans().getFirst().segmentIds().getFirst();
        assertEquals("READY", status(childSegment), "零料直制子件任务应直接可开工");
        view = analyses.detail(view.analysisId());
        var rootResult = commands.issueWorkshopPlans(view.analysisId(), new IssueWorkshopPlansRequest(
                view.version(), view.fingerprint(), "root-" + tag, w.warehouseId(),
                BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                        null, view.products().getFirst().analysisLineId(), new BigDecimal("100"),
                        BusinessTime.today(), BusinessTime.today().plusDays(10),
                        workshop, null, worker, null, null))));
        UUID plan = rootResult.plans().getFirst().planId();
        UUID segment = db.queryForObject(
                "SELECT id FROM production_execution_segments WHERE plan_id=? AND status='WAITING'", UUID.class, plan);
        UUID planItem = db.queryForObject(
                "SELECT source_plan_item_id FROM production_execution_segments WHERE id=?", UUID.class, segment);
        fixture.loginAs(workerUser);
        // V599：零料直制子件落生即 READY，开工前也要先确认齐套路线（唯一可选项）。
        confirmRoute(childPlan, childSegment, "FULL_KIT");
        segments.start(childPlan, childSegment,
                new SegmentTransitionRequest(version(childSegment), "cs-child-start-" + childSegment));
        return new Case(w, parent, child, secondMaterial, plan, segment, childPlan, childSegment,
                workshop, worker, workerUser, leaf, planItem);
    }

    /** 子件报工「转下一道工序」，投给父件对本子件的需求。 */
    private void transfer(Case c, String quantity, boolean isFinal) {
        fixture.loginAs(c.workerUser());
        var report = new DailyReportSaveRequest();
        report.setIdempotencyKey("cs-report-" + c.childSegment() + "-" + quantity + "-" + UUID.randomUUID());
        report.setBillDate(BusinessTime.today());
        report.setWarehouseId(c.leaf());
        report.setDepartmentId(c.workshop());
        report.setWorkerIds(List.of(c.worker()));
        var item = new DailyReportItemLine();
        item.setLineNo(1);
        item.setExecutionSegmentId(c.childSegment());
        item.setPlanItemId(db.queryForObject(
                "SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",
                UUID.class, c.childSegment()));
        item.setGoodsId(c.child());
        item.setUnitId(c.world().unitId());
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal(quantity));
        item.setIsFinal(isFinal);
        item.setDestination("WORKSHOP");
        item.setDirectTransferDemandId(parentDemand(c));
        report.setItems(List.of(item));
        reports.approve(reports.create(report).getId());
    }

    /** 父件按普通报工(送仓库)申报完工。 */
    private void reportParent(Case c, String quantity, boolean isFinal) {
        fixture.loginAs(c.workerUser());
        var report = new DailyReportSaveRequest();
        report.setIdempotencyKey("cs-parent-" + c.segment() + "-" + quantity + "-" + UUID.randomUUID());
        report.setBillDate(BusinessTime.today());
        report.setWarehouseId(c.leaf());
        report.setDepartmentId(c.workshop());
        report.setWorkerIds(List.of(c.worker()));
        var item = new DailyReportItemLine();
        item.setLineNo(1);
        item.setExecutionSegmentId(c.segment());
        item.setPlanItemId(c.planItem());
        item.setGoodsId(c.parent());
        item.setUnitId(c.world().unitId());
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal(quantity));
        item.setIsFinal(isFinal);
        // 父件来自销售订单：销售关联的执行段报工必须指定精确的销售分摊。
        Map<String, Object> allocation = db.queryForMap(
                "SELECT id, sales_order_item_id FROM execution_segment_sales_allocations WHERE execution_segment_id=?",
                c.segment());
        item.setExecutionSegmentSalesAllocationId((UUID) allocation.get("id"));
        item.setSalesOrderItemId((UUID) allocation.get("sales_order_item_id"));
        report.setItems(List.of(item));
        reports.approve(reports.create(report).getId());
    }

    private void receive(Case c, UUID goods, UUID warehouse, String quantity) {
        fixture.loginAs(c.world().superAdminUserId());
        var request = new StockDocSaveRequest();
        request.setDocType("OTHER_IN");
        request.setWarehouseId(warehouse);
        request.setBillDate(BusinessTime.today());
        var line = new StockDocItemLine();
        line.setGoodsId(goods);
        line.setUnitId(c.world().unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(quantity));
        line.setPrice(BigDecimal.TEN);
        line.setAmountOriginal(line.getQty().multiply(BigDecimal.TEN));
        line.setAmountLocal(line.getAmountOriginal());
        request.setItems(List.of(line));
        stock.approve(stock.create(request).getId());
    }

    /** 与 ReportablePlanLineQueryService / DailyReportExecutionSegmentGuard 同口径的直送折算上限。 */
    private BigDecimal maxReportQty(Case c) {
        Map<String, Object> row = db.queryForMap("""
                SELECT COALESCE(MIN(TRUNC((clearance.issued_qty - clearance.returned_qty) / demand.per_product_qty, 4)), 0) AS cap,
                       COALESCE((SELECT SUM(item.qty) FROM production_daily_report_items item
                                 JOIN production_daily_reports report ON report.id=item.report_id
                                 WHERE item.execution_segment_id=? AND NOT item.is_deleted
                                   AND NOT report.is_deleted AND report.status IN (0,1)), 0) AS reported
                FROM production_material_demands demand
                JOIN v_production_material_clearance clearance ON clearance.demand_id=demand.id
                WHERE demand.execution_segment_id=? AND demand.direct_supply AND NOT demand.is_deleted
                  AND demand.per_product_qty > 0
                """, c.segment(), c.segment());
        return ((BigDecimal) row.get("cap")).subtract((BigDecimal) row.get("reported")).max(BigDecimal.ZERO);
    }

    private int lineSideCount(UUID workshop) {
        return db.queryForObject(
                "SELECT count(*) FROM warehouses WHERE is_line_side AND workshop_department_id=? AND NOT is_deleted",
                Integer.class, workshop);
    }

    private UUID parentDemand(Case c) {
        return db.queryForObject(
                "SELECT id FROM production_material_demands WHERE execution_segment_id=? AND goods_id=?",
                UUID.class, c.segment(), c.child());
    }

    private BigDecimal reserved(UUID demandId) {
        return db.queryForObject(
                "SELECT COALESCE(SUM(qty - released_qty),0) FROM stock_reservations WHERE demand_id=? AND NOT is_deleted",
                BigDecimal.class, demandId);
    }

    private BigDecimal issued(UUID demandId) {
        return db.queryForObject(
                "SELECT COALESCE(SUM(consumed_qty),0) FROM stock_reservations WHERE demand_id=? AND NOT is_deleted",
                BigDecimal.class, demandId);
    }

    private BigDecimal balance(UUID warehouseId, UUID goodsId) {
        return db.queryForObject(
                "SELECT COALESCE(sum(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",
                BigDecimal.class, warehouseId, goodsId);
    }

    private long version(UUID id) {
        return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?", Long.class, id);
    }

    /** V599 / ADR-091：开工前先确认生产路线——未确认路线时开工侧动作被服务端拒绝。 */
    private void confirmRoute(UUID planId, UUID segmentId, String route) {
        segments.confirmRoute(planId, segmentId,
                new com.uten.imp.features.production.execution.SegmentRouteConfirmRequest(
                        version(segmentId), "route-" + route + "-" + segmentId, route));
    }

    private String status(UUID id) {
        return db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?", String.class, id);
    }

    private static void qty(String expected, BigDecimal value) {
        assertEquals(0, new BigDecimal(expected).compareTo(value), "expected " + expected + " but was " + value);
    }
}
