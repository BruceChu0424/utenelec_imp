package com.uten.imp.businesschain;

import com.uten.imp.support.DailyReportApproveRequests;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import com.uten.imp.features.production.execution.ProductionDrawRequest;
import com.uten.imp.features.production.execution.ProductionExecutionBatch;
import com.uten.imp.features.production.execution.ProductionExecutionSegmentService;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.production.mrp.ProductionExecutionBatchService;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.stock.StockDocService;
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
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.IssueWorkshopPlansRequest;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteDecision;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteRequest;
import static org.junit.jupiter.api.Assertions.*;

/**
 * 车间内部直送(ADR-087/V584-V585)的三条用户口径回归：
 *
 * <ol>
 *   <li>同车间直送全齐 → 父件工单自动提升并自动出库线边仓领料单，
 *       全程零领料申请、零仓库参与；</li>
 *   <li>直送只到一部分 → 车间按现有量「分批」，批次的线边仓领料单同样
 *       自动出库，不发领料申请；剩余工单继续等料；</li>
 *   <li>混合链（直送子件 + 仓库子件）→ 只有落在仓库的那部分需要领料申请。</li>
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
@org.springframework.context.annotation.Import(ProductionJdbcMeasurement.Configuration.class)
class WorkshopDirectTransferBatchEndToEndTest {

    /**
     * 一行车间直送审核的语句预算(2026-09-22 实测 490 条, 留一点余量)。
     *
     * <p>这个数字是拿来挡回归的，不是拿来抬的：抬它之前先跑这条用例看剖面，
     * 确认多出来的语句是新做的事而不是又一遍重复的读。
     */
    private static final int APPROVE_STATEMENTS_BUDGET = 520;
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionExecutionBatchService batches;
    @Autowired ProductionExecutionSegmentService segments;
    @Autowired ProductionDailyReportService reports;
    @Autowired com.uten.imp.features.production.execution.ProductionDrawRequestService drawRequests;
    @Autowired StockDocService stock;
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
    void fullDirectTransferPromotesParentReadyAndAutoIssuesWithoutAnyDrawRequest() {
        Case c = create("dt-full", false);
        // V599：先确认齐套路线——未确认路线时直送到料的自动提升同样被抑制。
        fixture.loginAs(c.workerUser());
        confirmRoute(c.plan(), c.segment(), "FULL_KIT");
        transfer(c, "100");
        assertEquals("READY", status(c.segment()));
        assertEquals("FULFILLED", db.queryForObject(
                "SELECT status FROM production_material_demands WHERE execution_segment_id=? AND goods_id=?",
                String.class, c.segment(), c.child()));
        var draw = drawOf(c.segment());
        assertEquals(c.lineSide(), draw.get("warehouse_id"));
        assertAutoIssued(draw, "100");
        assertEquals(0, drawRequestCount(c.segment()), "全直送链路不得出现领料申请事件");
        qty("0", db.queryForObject(
                "SELECT COALESCE(sum(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",
                BigDecimal.class, c.lineSide(), c.child()));
        assertEquals(1, db.queryForObject(
                "SELECT count(*) FROM production_workshop_direct_transfer_items WHERE to_demand_id=? AND reversal_id IS NULL",
                Integer.class, parentDemand(c)), "直送行应精确挂到父件需求");
        // 用户口径：子件齐了就是可开工，不需要任何领料动作。
        fixture.loginAs(c.workerUser());
        var started = segments.start(c.plan(), c.segment(),
                new SegmentTransitionRequest(version(c.segment()), "dt-full-start-" + c.segment()));
        assertEquals("IN_PROGRESS", started.status());
        assertTrue(started.materialIssued());
    }

    /**
     * 直送审核的语句预算(2026-09-22)。
     *
     * <p>一次审核必须是一笔事务，且语句条数守在上限内。上限是刻意钉死的：审核是整条报工链
     * 最重的一次写，Flutter Web 对慢写请求的容忍度有限，谁把它做慢了要在这里先红一次。
     * 2026-09-22 实测：一行直送审核 490 条语句、约 2.0 秒 JDBC + 0.4 秒提交。
     */
    @Test
    void oneDirectTransferApproveStaysInsideItsStatementBudget() {
        Case c = create("dt-budget", false);
        fixture.loginAs(c.workerUser());
        confirmRoute(c.plan(), c.segment(), "FULL_KIT");

        var sample = measureTransferApprove(c, "100");

        // 超预算时把剖面打出来，省得下一个人还要自己加日志再跑一遍两百秒。
        if (sample.logicalStatements > APPROVE_STATEMENTS_BUDGET) {
            sample.fingerprints.entrySet().stream()
                    .sorted((a, b) -> Long.compare(b.getValue(), a.getValue()))
                    .limit(20)
                    .forEach(entry -> System.out.println("APPROVE-PROFILE "
                            + entry.getKey() + " calls=" + entry.getValue()
                            + " millis=" + (sample.nanosByFingerprint
                                    .getOrDefault(entry.getKey(), 0L) / 1_000_000.0)
                            + " label=" + sample.labelsByFingerprint.get(entry.getKey())));
        }
        assertEquals(1, sample.commits, "审核必须是一笔事务，剖面才有意义");
        assertTrue(sample.logicalStatements <= APPROVE_STATEMENTS_BUDGET,
                "一行直送审核用了 " + sample.logicalStatements
                        + " 条语句，超出预算 " + APPROVE_STATEMENTS_BUDGET
                        + "；先量再改，别直接抬预算");
        // 顺带确认省下来的不是靠少做事：父件照样提升、领料单照样自动出库。
        assertEquals("READY", status(c.segment()));
        assertAutoIssued(drawOf(c.segment()), "100");
    }

    /**
     * permissions-15：日报的「审核」按钮由服务端随详情下发(allowedActions)。带车间直送行的
     * 草稿，只持日报审核码、没有车间直送审核权的人，或者两个码都有但不是出料车间成员的人，
     * 都拿不到 APPROVE——与审核写路径同一口径，不会再出现按钮亮着、点了才报没有权限。
     */
    @Test
    void directTransferDraftOffersApproveOnlyToHoldersOfTheDirectTransferCode() {
        Case c = create("dt-actions", false);
        fixture.loginAs(c.workerUser());
        confirmRoute(c.plan(), c.segment(), "FULL_KIT");
        var report = new DailyReportSaveRequest();
        report.setIdempotencyKey("dt-actions-" + c.segment());
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
        item.setQty(new BigDecimal("10"));
        item.setIsFinal(false);
        item.setDestination("WORKSHOP");
        item.setDirectTransferDemandId(parentDemand(c));
        report.setItems(List.of(item));
        UUID reportId = reports.create(report).getId();

        assertEquals(List.of("APPROVE"), reports.detail(reportId).getAllowedActions(),
                "持日报审核 + 车间直送审核的人：可审核");

        UUID approverOnly = fixture.createUserWithPerms(c.world(), "dt-approver-only",
                "production_daily_report:view", "production_daily_report:approve");
        fixture.loginAs(approverOnly);
        assertEquals(List.of(), reports.detail(reportId).getAllowedActions(),
                "只持日报审核码：带直送行的草稿不下发审核动作");

        // 两个码都有，但不是出料工单所属车间的成员：直送写路径会拒绝，按钮同样不下发。
        UUID outsider = fixture.createUserWithPerms(c.world(), "dt-approver-outsider",
                "production_daily_report:view", "production_daily_report:approve",
                "production_direct_transfer:approve");
        fixture.loginAs(outsider);
        assertEquals(List.of(), reports.detail(reportId).getAllowedActions(),
                "不是该车间成员：带直送行的草稿不下发审核动作");

        fixture.loginAs(c.workerUser());
        reports.approve(reportId, DailyReportApproveRequests.freshKey());
        assertEquals(List.of(), reports.detail(reportId).getAllowedActions(), "已审核后不再下发审核动作");
    }

    @Test
    void partialDirectTransferSplitsAnAutoIssuedBatchWithoutDrawRequest() {
        Case c = create("dt-partial", false);
        // V599：分批链先确认分批路线，根段不再被自动提升。
        fixture.loginAs(c.workerUser());
        confirmRoute(c.plan(), c.segment(), "BATCH");
        transfer(c, "40");
        assertEquals("WAITING", status(c.segment()), "未全齐时父件继续等待物料");
        fixture.loginAs(c.workerUser());
        var preview = batches.preview(new ProductionExecutionBatch.PreviewRequest(
                c.segment(), version(c.segment()), null));
        qty("40", preview.maxReadyQty());
        qty("60", preview.remainingQty());
        assertEquals(List.of(c.lineSide()), preview.lineSideWarehouseIds());
        assertEquals(1, preview.summaries().size());
        qty("40", preview.summaries().getFirst().qty());
        var result = batches.submit(new ProductionExecutionBatch.SubmitRequest(
                c.segment(), preview.expectedVersion(), preview.quantity(),
                preview.fingerprint(), "dt-batch-" + c.segment()));
        assertEquals("READY", status(result.batchSegmentId()));
        assertEquals("WAITING", status(result.remainingSegmentId()));
        var draw = drawOf(result.batchSegmentId());
        assertEquals(c.lineSide(), draw.get("warehouse_id"));
        assertAutoIssued(draw, "40");
        assertEquals(0, drawRequestCount(result.batchSegmentId()), "分批直送不得发领料申请");
        var started = segments.start(c.plan(), result.batchSegmentId(),
                new SegmentTransitionRequest(version(result.batchSegmentId()), "dt-partial-start-" + result.batchSegmentId()));
        assertEquals("IN_PROGRESS", started.status());
        assertTrue(started.materialIssued());
        // 直送料不滞留线边仓：40 已随批次自动投入。
        assertEquals(0, java.util.Objects.compare(
                db.queryForObject(
                        "SELECT COALESCE(sum(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",
                        BigDecimal.class, c.lineSide(), c.child()),
                BigDecimal.ZERO, BigDecimal::compareTo));
    }

    @Test
    void mixedChainOnlyWarehousePartNeedsDrawRequest() {
        Case c = create("dt-mixed", true);
        // V599：先确认齐套路线，直送+仓库混合链的自动提升才放行。
        fixture.loginAs(c.workerUser());
        confirmRoute(c.plan(), c.segment(), "FULL_KIT");
        receive(c, c.secondMaterial(), c.leaf(), "100");
        transfer(c, "100");
        assertEquals("READY", status(c.segment()));
        var draws = db.queryForList("""
                SELECT document.warehouse_id AS warehouse_id, document.status AS status,
                       document.is_closed AS closed
                FROM production_planning_package_documents mapping
                JOIN stock_documents document ON document.id=mapping.document_id
                WHERE mapping.execution_segment_id=? AND mapping.document_type='DRAW'
                GROUP BY document.warehouse_id, document.status, document.is_closed
                """, c.segment());
        assertEquals(2, draws.size());
        for (var row : draws) {
            if (c.lineSide().equals(row.get("warehouse_id"))) {
                assertEquals(1, ((Number) row.get("status")).intValue(), "直送部分自动审核");
                assertEquals(Boolean.TRUE, row.get("closed"), "直送部分自动出库结清");
            } else {
                assertEquals(c.leaf(), row.get("warehouse_id"));
                assertEquals(0, ((Number) row.get("status")).intValue(), "仓库部分保持草稿待车间申请");
                assertEquals(Boolean.FALSE, row.get("closed"));
            }
        }
        fixture.loginAs(c.workerUser());
        assertThrows(ApiException.class, () -> segments.start(c.plan(), c.segment(),
                new SegmentTransitionRequest(version(c.segment()), "dt-mixed-early-" + c.segment())));
        var items = List.of(new ProductionDrawRequest.Item(c.segment(), version(c.segment())));
        var preview = drawRequests.preview(new ProductionDrawRequest.PreviewRequest(items));
        assertEquals(1, preview.lines().size(), "领料汇总只剩仓库子件，直送子件不再出现");
        assertEquals(c.secondMaterial(), preview.lines().getFirst().goodsId());
        qty("100", preview.lines().getFirst().qty());
        var submitted = drawRequests.submit(new ProductionDrawRequest.SubmitRequest(
                items, "dt-mixed-request-" + c.segment(), preview.fingerprint()));
        fixture.loginAs(c.world().superAdminUserId());
        var issue = new StockDocIssueBatchRequest();
        issue.setIdempotencyKey("dt-mixed-issue-" + c.segment());
        issue.setDocIds(submitted.documentIds());
        stock.issueFullBatch(issue);
        fixture.loginAs(c.workerUser());
        var started = segments.start(c.plan(), c.segment(),
                new SegmentTransitionRequest(version(c.segment()), "dt-mixed-start-" + c.segment()));
        assertEquals("IN_PROGRESS", started.status());
    }

    // 「线边仓公共库存被无谱系任务占用→重核提升→自动投入资格拒绝」的构造依赖
    // 「先有兄弟需求、再做直送审核」，而那条直送审核会先被既有足迹守卫拦下
    //（来源集合含同货品兄弟计划，预读后变化）——即该状态在现有链路上不可达，
    // 预检（issueLineSideDrawsAfterPromotion）作为纵深防御保留，不另设测试锁定。

    // ===================== 夹具 =====================

    private record Case(
            FullChainEndToEndTest.World world,
            UUID parent, UUID child, UUID secondMaterial,
            UUID plan, UUID segment,
            UUID childPlan, UUID childSegment,
            UUID workshop, UUID worker, UUID workerUser,
            UUID leaf, UUID lineSide) {
    }

    /** 父件(自制) → 子件(自制叶子，零料直制)；可选第二种采购子件。主仓下挂普通叶子子仓 + 车间线边仓。 */
    private Case create(String tag, boolean withBuyMaterial) {
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        UUID parent = UUID.randomUUID(), child = UUID.randomUUID();
        UUID secondMaterial = withBuyMaterial ? UUID.randomUUID() : null;
        fixture.insertGoods(parent, "P-" + tag, "直送父件-" + tag, "自制", w.unitId(), w.unitLegacy());
        fixture.insertGoods(child, "CL-" + tag, "直送子件-" + tag, "自制", w.unitId(), w.unitLegacy());
        fixture.insertBom(parent, child, "1");
        if (withBuyMaterial) {
            fixture.insertGoods(secondMaterial, "MAT-" + tag, "仓库子件-" + tag, "采购", w.unitId(), w.unitLegacy());
            fixture.insertBom(parent, secondMaterial, "1");
        }
        UUID production = db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD'", UUID.class);
        UUID workshop = UUID.randomUUID(), worker = UUID.randomUUID();
        db.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES(?,?,?,?,'二级班组')",
                workshop, "W-" + tag, "直送车间-" + tag, production);
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')
                """, worker, "DT-WORKER-" + tag, "直送负责人-" + tag, workshop);
        UUID workerUser = fixture.createUserWithPerms(w, "dt-worker-" + tag,
                "production_execution:view", "production_execution:start",
                "production_daily_report:view", "production_daily_report:create",
                "production_daily_report:approve", "production_direct_transfer:approve");
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",
                workshop, workerUser);
        UUID leaf = UUID.randomUUID(), lineSide = UUID.randomUUID();
        db.update("""
                INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable)
                VALUES(?,?,?,?,'使用',TRUE)
                """, leaf, "SUB-" + tag, "普通子仓-" + tag, w.warehouseId());
        db.update("""
                INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable,is_line_side,workshop_department_id)
                VALUES(?,?,?,?,'使用',TRUE,TRUE,?)
                """, lineSide, "LS-" + tag, "线边仓-" + tag, w.warehouseId(), workshop);
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
        // 子件开工后才能报工直送。
        fixture.loginAs(workerUser);
        // V599：零料直制子件开工前先确认齐套路线。
        confirmRoute(childPlan, childSegment, "FULL_KIT");
        segments.start(childPlan, childSegment,
                new SegmentTransitionRequest(version(childSegment), "dt-child-start-" + childSegment));
        return new Case(w, parent, child, secondMaterial, plan, segment, childPlan, childSegment,
                workshop, worker, workerUser, leaf, lineSide);
    }

    /** 子件报工选「转下一道工序」，把产出直送给父件对本子件的需求。 */
    private void transfer(Case c, String quantity) {
        fixture.loginAs(c.workerUser());
        var report = new DailyReportSaveRequest();
        report.setIdempotencyKey("dt-report-" + c.segment() + "-" + quantity);
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
        item.setIsFinal(false);
        item.setDestination("WORKSHOP");
        item.setDirectTransferDemandId(parentDemand(c));
        report.setItems(List.of(item));
        reports.approve(reports.create(report).getId(), DailyReportApproveRequests.freshKey());
    }

    /** 同 {@link #transfer}，但只对「审核」那一段计量，返回本次审核的 JDBC 剖面。 */
    private ProductionJdbcMeasurement.Sample measureTransferApprove(
            Case c, String quantity) {
        fixture.loginAs(c.workerUser());
        var report = new DailyReportSaveRequest();
        report.setIdempotencyKey("dt-probe-" + c.segment() + "-" + quantity);
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
        item.setIsFinal(false);
        item.setDestination("WORKSHOP");
        item.setDirectTransferDemandId(parentDemand(c));
        report.setItems(List.of(item));
        UUID reportId = reports.create(report).getId();
        ProductionJdbcMeasurement.Sample sample = ProductionJdbcMeasurement.begin();
        try {
            reports.approve(reportId, DailyReportApproveRequests.freshKey());
        } finally {
            ProductionJdbcMeasurement.end();
        }
        return sample;
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

    private UUID parentDemand(Case c) {
        return db.queryForObject(
                "SELECT id FROM production_material_demands WHERE execution_segment_id=? AND goods_id=?",
                UUID.class, c.segment(), c.child());
    }

    private java.util.Map<String, Object> drawOf(UUID segmentId) {
        return db.queryForMap("""
                SELECT document.warehouse_id AS warehouse_id, document.status AS status,
                       document.is_closed AS closed,
                       sum(item.issued_qty) AS issued
                FROM production_planning_package_documents mapping
                JOIN stock_documents document ON document.id=mapping.document_id
                JOIN stock_document_items item ON item.doc_id=document.id AND NOT item.is_deleted
                WHERE mapping.execution_segment_id=? AND mapping.document_type='DRAW'
                GROUP BY document.warehouse_id, document.status, document.is_closed
                """, segmentId);
    }

    /** 「审核并出库」后的终态：已审(1)+closed+足额 issued_qty。 */
    private static void assertAutoIssued(java.util.Map<String, Object> draw, String qty) {
        assertEquals(1, ((Number) draw.get("status")).intValue(), "直送领料单应已自动审核");
        assertEquals(Boolean.TRUE, draw.get("closed"), "直送领料单应已自动出库结清");
        qty(qty, (BigDecimal) draw.get("issued"));
    }

    private int drawRequestCount(UUID segmentId) {
        return db.queryForObject(
                "SELECT count(*) FROM production_execution_segment_events WHERE execution_segment_id=? AND action='DRAW_REQUEST'",
                Integer.class, segmentId);
    }

    /** V599 / ADR-091：开工前先确认生产路线——未确认路线时开工侧动作被服务端拒绝。 */
    private void confirmRoute(UUID planId, UUID segmentId, String route) {
        segments.confirmRoute(planId, segmentId,
                new com.uten.imp.features.production.execution.SegmentRouteConfirmRequest(
                        version(segmentId), "route-" + route + "-" + segmentId, route));
    }

    private long version(UUID id) {
        return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?", Long.class, id);
    }

    private String status(UUID id) {
        return db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?", String.class, id);
    }

    private static void qty(String expected, BigDecimal value) {
        assertEquals(0, new BigDecimal(expected).compareTo(value));
    }
}
