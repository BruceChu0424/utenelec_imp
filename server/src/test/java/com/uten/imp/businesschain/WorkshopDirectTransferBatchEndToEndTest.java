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
import com.uten.imp.features.production.execution.SegmentAssignmentRequest;
import com.uten.imp.features.production.mrp.ProductionExecutionBatchService;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.ReportablePlanLineQueryService;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.mrp.BottomUpPlanOrchestrator;
import com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest;
import com.uten.imp.features.production.mrp.ProductionPlanningPackageService;
import com.uten.imp.features.production.mrp.MrpService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.quality.ProductionFqcContracts.DecisionRequest;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationItemRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
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
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!",
        // 量的是生产配置: 关掉测试默认打开的嵌套足迹诊断(ADR-107)。
        "uten.concurrency.verify-nested-footprint=false"})
@org.springframework.context.annotation.Import(ProductionJdbcMeasurement.Configuration.class)
class WorkshopDirectTransferBatchEndToEndTest {

    /**
     * 一行车间直送审核的语句预算(2026-09-22 实测 490 条; 2026-09-23 ADR-107 预锁只发现一轮、
     * 锁后只比行版本、会话变量每事务只绑一次之后实测 385 条, 预算取实测 +10%)。
     *
     * <p>这个数字是拿来挡回归的，不是拿来抬的：抬它之前先跑这条用例看剖面，
     * 确认多出来的语句是新做的事而不是又一遍重复的读。
     */
    private static final int APPROVE_STATEMENTS_BUDGET = 424;

    /**
     * 一行车间直送审核里触发器函数的调用预算(ADR-106)。统计口径：pg_stat_user_functions 里
     * 返回 trigger 的函数调用次数之和。2026-09-23 实测：V645 为 600 次(延迟校验 282 次)，
     * V674-V676 后为 416 次(延迟校验 170 次；总数里 160 次是审计触发器 fn_audit / fn_audit_classify_row)。
     */
    private static final long APPROVE_TRIGGER_CALLS_BUDGET = 450;
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
    @Autowired org.springframework.transaction.PlatformTransactionManager transactionManager;
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
        assertEquals(0, sample.md5Statements, "预锁锁后复核只比行版本, 不再对整行做哈希(ADR-107)");
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

    /**
     * 直送审核的触发器调用剖面(ADR-106)。
     *
     * <p>只在这一笔审核事务里打开 track_functions，统计各触发器函数被调了几次，同时拿
     * ProductionJdbcMeasurement 的提交耗时。V674 给热表的约束/守卫触发器补了「相关列真变了」
     * 的 WHEN 条件、删掉了被包含的重复校验，V675 撤掉了 52 张表上的货品单位锁语句级触发器；
     * 这里把调用总数钉住，谁把无关更新又接回校验上要先在这里红一次。
     */
    @Test
    void oneDirectTransferApproveKeepsTriggerCallsInsideBudget() throws Exception {
        Case c = create("dt-trigger-budget", false);
        fixture.loginAs(c.workerUser());
        confirmRoute(c.plan(), c.segment(), "FULL_KIT");

        var profile = profileTransferApprove(c, "100");

        System.out.println("APPROVE-TRIGGER-PROFILE total=" + profile.triggerCalls()
                + " deferredChecks=" + profile.deferredCheckCalls()
                + " commitMillis=" + profile.sample().commitNanos / 1_000_000.0
                + " jdbcMillis=" + profile.sample().jdbcNanos / 1_000_000.0
                + " statements=" + profile.sample().logicalStatements
                + " top=" + profile.top());
        assertEquals(1, profile.sample().commits, "审核必须是一笔事务，剖面才有意义");
        assertEquals(0, profile.calls().getOrDefault("fn_lock_goods_quantity_unit_from_references", 0L),
                "货品单位锁已改为改单位时按需检查，写业务行不再走语句级触发器");
        assertTrue(profile.triggerCalls() <= APPROVE_TRIGGER_CALLS_BUDGET,
                "一行直送审核触发器函数被调了 " + profile.triggerCalls() + " 次，超出预算 "
                        + APPROVE_TRIGGER_CALLS_BUDGET + "；先看剖面是哪条触发器又对无关列更新起跳");
        assertEquals("none", db.queryForObject("SHOW track_functions", String.class),
                "track_functions 只在被测事务里打开，不能漏到后面的用例");
        assertEquals("READY", status(c.segment()));
        assertAutoIssued(drawOf(c.segment()), "100");
    }

    /**
     * V674 收窄的负向回归(ADR-106)：拿一条真实直送链的单据、预留、执行段、计划明细、分析行、估值节点，
     * 每类收窄各做两件事——改了相关列照样被拒；只改无关列时对应校验函数一次都不被调用。
     * 每个探针都在自己的事务里做完就回滚，不留任何痕迹。
     */
    @Test
    void narrowedTriggersStillRejectRelevantChangesAndSkipIrrelevantOnes() {
        Case c = create("dt-trigger-gates", false);
        fixture.loginAs(c.workerUser());
        confirmRoute(c.plan(), c.segment(), "FULL_KIT");
        transfer(c, "100");
        assertEquals("READY", status(c.segment()));

        UUID draw = db.queryForObject("""
                SELECT mapping.document_id FROM production_planning_package_documents mapping
                WHERE mapping.execution_segment_id=? AND mapping.document_type='DRAW'
                """, UUID.class, c.segment());
        UUID drawItem = db.queryForObject(
                "SELECT id FROM stock_document_items WHERE doc_id=? AND NOT is_deleted ORDER BY id LIMIT 1",
                UUID.class, draw);
        UUID reservation = db.queryForObject("""
                SELECT id FROM stock_reservations
                WHERE demand_id=? AND owner_type='PRODUCTION_MATERIAL_DEMAND' ORDER BY id LIMIT 1
                """, UUID.class, parentDemand(c));
        UUID planItem = db.queryForObject(
                "SELECT id FROM production_plan_items WHERE plan_id=? AND NOT is_deleted", UUID.class, c.plan());
        UUID analysisItem = db.queryForObject(
                "SELECT material_analysis_item_id FROM production_plans WHERE id=?", UUID.class, c.plan());
        UUID rootMaterial = db.queryForObject("""
                SELECT id FROM production_material_analysis_materials
                WHERE node_role='ROOT_SUPPLY' AND active ORDER BY (analysis_item_id=?) DESC, created_at DESC LIMIT 1
                """, UUID.class, analysisItem);
        UUID exactNode = db.queryForObject("""
                SELECT id FROM stock_value_nodes WHERE value_model='EXACT_SOURCE_SHARES' AND active
                  AND bound_scale IS NOT NULL AND bound_scale < 256
                ORDER BY node_sequence DESC LIMIT 1
                """, UUID.class);

        // 单号不可变：改单号、改单据类型照样拒；改备注不进任何单号函数。
        rejected("UPDATE stock_documents SET bill_no=bill_no||'X' WHERE id=?", draw, "is immutable after creation");
        rejected("UPDATE stock_documents SET doc_type='OTHER_OUT' WHERE id=?", draw,
                "doc_type is immutable after identifier creation");
        assertEquals(0, callsDuring("UPDATE stock_documents SET remark='只改备注' WHERE id=?", draw,
                "fn_reserve_business_document_identifier", "fn_guard_business_document_identifier_immutable",
                "fn_guard_production_linked_stock_document", "fn_check_make_receipt_source",
                "fn_check_receipt_draw_provenance", "fn_check_subcontract_receipt_provenance_source",
                "fn_check_subcontract_preparation_finished_source"));

        // 生产关联领料单：换仓照样拒；明细改数量照样拒；只动时间戳一次都不查。
        rejected("UPDATE stock_documents SET warehouse_id=? WHERE id=?", new Object[]{c.leaf(), draw},
                "production-linked stock document identity is immutable");
        rejected("UPDATE stock_document_items SET qty=qty+1 WHERE id=?", drawItem,
                "production-linked stock document item is immutable");
        assertEquals(0, callsDuring("UPDATE stock_document_items SET updated_at=now() WHERE id=?", drawItem,
                "fn_guard_production_linked_stock_document_item", "fn_check_execution_segment_integrity",
                "fn_check_make_receipt_source", "fn_check_receipt_draw_provenance",
                "fn_assert_execution_segment_sales_fact_row", "fn_check_subcontract_preparation_finished_source"));

        // 生产需求预留：只改释放原因，延迟校验一次都不排；改相关列(来回改一次)照样全部排队，且终态合法。
        assertEquals(0, callsDuring("UPDATE stock_reservations SET release_reason='只改原因' WHERE id=?", reservation,
                "fn_check_material_consumed_projection", "fn_check_workshop_source_event_balance",
                "fn_assert_workshop_direct_source_allocation", "fn_check_make_receipt_source",
                "fn_check_purchase_receipt_conservation", "fn_check_subcontract_receipt_reservation",
                "fn_check_execution_segment_integrity", "fn_check_workshop_custody_reservation_grant",
                "fn_check_main_warehouse_public_stock_budget", "fn_validate_preplan_entitlement_conservation",
                "fn_check_subcontract_outbound_reservation", "fn_check_subcontract_prepared_source_capacity",
                "fn_check_subcontract_qualified_preparation_reservation", "fn_check_root_sales_reservation_release",
                "fn_guard_qualified_origin_reservation_identity", "fn_guard_workshop_custody_reservation"));
        assertTrue(callsDuring(new String[]{
                        "UPDATE stock_reservations SET source=source+1 WHERE id=?",
                        "UPDATE stock_reservations SET source=source-1 WHERE id=?"}, reservation,
                "fn_check_workshop_source_event_balance", "fn_assert_workshop_direct_source_allocation",
                "fn_check_make_receipt_source", "fn_check_workshop_custody_reservation_grant") >= 8,
                "相关列真变了，四条延迟校验在两次更新上都要排队");
        // 已耗用量改动而没有同事务的出库事实：预留量同减 1，已耗用 + 已释放仍等于预留量(过得了生命周期 CHECK)、
        // 释放量不动(不进直送来源释放守卫)；只把被收窄的耗用投影校验立即执行，拒绝必须来自它的约束名。
        rejected("UPDATE stock_reservations SET consumed_qty=consumed_qty-1, qty=qty-1 WHERE id=?",
                new Object[]{reservation}, "trg_check_material_reservation_consumed_projection_upd",
                "production_material_consumed_projection_guard");

        // 执行段：改计划数、改拆批谱系照样拒；只动时间戳不查完整性(锁版本号每次都会被递增)。
        rejected("UPDATE production_execution_segments SET planned_qty=planned_qty+1 WHERE id=?", c.segment(),
                "frozen identity is immutable");
        rejected("UPDATE production_execution_segments SET split_start_qty=split_start_qty+1 WHERE id=?",
                c.segment(), "Execution split lineage is immutable");
        assertEquals(0, callsDuring("UPDATE production_execution_segments SET updated_at=now() WHERE id=?",
                c.segment(), "fn_check_execution_segment_integrity", "fn_assert_execution_segment_sales_allocation_segment",
                "fn_check_final_report_target_change", "fn_guard_execution_split_history",
                "fn_guard_material_snapshot_product_qty", "fn_guard_execution_confirmed_route_start",
                "fn_guard_execution_segment_requirement_shape", "fn_guard_production_assignment_scope"));

        // 物料分析计划明细：改数量照样拒；只改备注不进身份守卫。
        rejected("UPDATE production_plan_items SET qty=qty+1 WHERE id=?", planItem,
                "material-analysis plan item identity and quantity are immutable");
        assertEquals(0, callsDuring("UPDATE production_plan_items SET remark='只改备注' WHERE id=?", planItem,
                "fn_guard_material_analysis_plan_item_identity", "fn_check_execution_segment_integrity",
                "fn_check_make_receipt_source", "fn_check_subcontract_preparation_finished_source",
                "fn_guard_production_supply_source_item"));

        // 分析来源行：改已完成量照样被拒；改已批准量(来回一次)照样排队产出台账校验；只改交期不进任何校验。
        // 已完成量加 1、已批准量减 1：三者合计不超过申请量(过得了 CHECK)，只让产出台账校验立即执行。
        rejected("UPDATE production_material_analysis_items"
                        + " SET root_fulfilled_qty=root_fulfilled_qty+1, approved_qty=approved_qty-1 WHERE id=?",
                new Object[]{analysisItem}, "trg_check_root_output_quantity_upd",
                "root fulfilled quantity must equal output event ledger");
        assertTrue(callsDuring(new String[]{
                        "UPDATE production_material_analysis_items SET approved_qty=approved_qty-1 WHERE id=?",
                        "UPDATE production_material_analysis_items SET approved_qty=approved_qty+1 WHERE id=?"},
                analysisItem, "fn_check_root_output_quantity") >= 2,
                "已批准量真变了，产出台账校验在两次更新上都要排队");
        assertEquals(0, callsDuring(
                "UPDATE production_material_analysis_items SET delivery_date=delivery_date+1 WHERE id=?",
                analysisItem, "fn_check_root_output_quantity", "fn_check_root_material_owner",
                "fn_check_subcontract_preparation_analysis_source", "fn_bind_direct_subcontract_preparation",
                "fn_guard_preplan_direct_make_source_identity", "fn_guard_subcontract_qualified_source_identity"));

        // 分析物料行：改根供给换算照样拒；只改缺口派生量不进任何守卫。
        rejected("UPDATE production_material_analysis_materials SET per_product_qty=per_product_qty+1 WHERE id=?",
                rootMaterial, "root supply dimension and conversion are immutable");
        assertEquals(0, callsDuring(
                "UPDATE production_material_analysis_materials SET shortage_qty=shortage_qty+1 WHERE id=?",
                rootMaterial, "fn_guard_root_material_identity", "fn_validate_pma_material_exact_peg_endpoint",
                "fn_validate_production_material_analysis_borrow_endpoint", "fn_validate_preplan_material_reallocation_endpoints",
                "fn_guard_pma_material_exact_peg_identity", "fn_guard_preplan_subcontract_handoff_material_identity",
                "fn_guard_root_supply_route"));

        // 估值节点：界版本与修订号不一致照样拒；只改显示精度位数不进精度界/生命周期/成本分摊校验。
        rejected("UPDATE stock_value_nodes SET bound_revision=bound_revision+1 WHERE id=?", exactNode,
                "金额精度界必须覆盖同版来源表达式");
        assertEquals(0, callsDuring(
                "UPDATE stock_value_nodes SET bound_scale=bound_scale+1 WHERE id=?", exactNode,
                "fn_check_stock_value_exact_bounds", "fn_check_stock_value_node_lifecycle",
                "fn_check_stock_value_cost_distribution", "fn_check_consumption_return",
                "fn_check_stock_value_node_revision", "fn_guard_stock_value_exact_identity"));
    }

    /** 在一笔回滚事务里执行更新并立即跑完全部延迟校验，返回这些函数在本事务里被调用的次数。 */
    private long callsDuring(String sql, Object argument, String... functions) {
        return callsDuring(new String[]{sql}, argument, functions);
    }

    private long callsDuring(String[] statements, Object argument, String... functions) {
        String names = String.join(",", functions);
        Long calls = new org.springframework.transaction.support.TransactionTemplate(transactionManager)
                .execute(status -> {
                    status.setRollbackOnly();
                    db.execute("SET LOCAL track_functions = 'all'");
                    // 后端里未冲刷的计数可能带着上一笔事务的调用，取本事务前后差值。
                    long before = pendingCalls(names);
                    for (String statement : statements) {
                        db.update(statement, argument);
                    }
                    db.execute("SET CONSTRAINTS ALL IMMEDIATE");
                    return pendingCalls(names) - before;
                });
        return calls == null ? -1 : calls;
    }

    private long pendingCalls(String names) {
        Long calls = db.queryForObject("""
                SELECT COALESCE(SUM(pg_stat_get_xact_function_calls(p.oid)), 0)
                FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
                WHERE p.proname = ANY (string_to_array(?, ','))
                """, Long.class, names);
        return calls == null ? 0 : calls;
    }

    private void rejected(String sql, Object argument, String expected) {
        rejected(sql, new Object[]{argument}, expected);
    }

    /**
     * 相关列改动必须被拒：立即守卫当场拒，延迟校验在 SET CONSTRAINTS ALL IMMEDIATE 时拒。
     * expected 是期望的报错原文片段或数据库约束名，二者命中其一——只看 SQLState 不够，普通 CHECK 约束也报 23514，
     * 证明不了拒绝来自被收窄的那条校验。
     */
    private void rejected(String sql, Object[] arguments, String expected) {
        rejected(sql, arguments, "ALL", expected);
    }

    /** constraints 为要立即执行的延迟约束(逗号分隔的约束触发器名或 ALL)；点名时其它延迟校验不跑，随回滚丢弃。 */
    private void rejected(String sql, Object[] arguments, String constraints, String expected) {
        var failure = assertThrows(org.springframework.dao.DataAccessException.class, () ->
                new org.springframework.transaction.support.TransactionTemplate(transactionManager)
                        .executeWithoutResult(status -> {
                            status.setRollbackOnly();
                            db.update(sql, arguments);
                            db.execute("SET CONSTRAINTS " + constraints + " IMMEDIATE");
                        }), sql);
        Throwable cause = failure;
        while (cause.getCause() != null) cause = cause.getCause();
        assertInstanceOf(java.sql.SQLException.class, cause, sql);
        String state = ((java.sql.SQLException) cause).getSQLState();
        assertTrue("23514".equals(state) || "55000".equals(state), sql + " -> " + state + " " + cause.getMessage());
        String constraint = cause instanceof org.postgresql.util.PSQLException server
                && server.getServerErrorMessage() != null ? server.getServerErrorMessage().getConstraint() : null;
        assertTrue(expected.equals(constraint) || cause.getMessage().contains(expected),
                sql + " -> 约束 " + constraint + "：" + cause.getMessage());
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

    @Test
    void defaultContinuousRouteIsEffectiveAuditedChangeableAndStillRequiresPhysicalStart() {
        Case c = create("dt-default-route", false);
        assertEquals("CONTINUOUS", db.queryForObject("SELECT start_route FROM production_execution_segments WHERE id=?",
                String.class, c.segment()));
        assertEquals(Boolean.TRUE, db.queryForObject("SELECT continuous_supply AND route_confirmed_at IS NOT NULL FROM production_execution_segments WHERE id=?",
                Boolean.class, c.segment()));
        assertEquals(1, db.queryForObject("SELECT count(*) FROM production_execution_segment_events WHERE execution_segment_id=? AND action='ROUTE_DEFAULTED' AND created_by IS NULL",
                Integer.class, c.segment()), "默认路线由系统留痕，不能伪造人工确认");
        assertEquals(0, db.queryForObject("SELECT count(*) FROM production_execution_segment_events WHERE execution_segment_id=? AND action='ROUTE_CONFIRMED'",
                Integer.class, c.segment()));
        fixture.loginAs(c.workerUser());
        assertThrows(ApiException.class, () -> segments.start(c.plan(), c.segment(),
                new SegmentTransitionRequest(version(c.segment()), "default-without-material-" + c.segment())));
        confirmRoute(c.plan(), c.segment(), "FULL_KIT");
        assertEquals("FULL_KIT", db.queryForObject("SELECT start_route FROM production_execution_segments WHERE id=?", String.class, c.segment()));
        confirmRoute(c.plan(), c.segment(), "CONTINUOUS");
        transfer(c, "40");
        assertNotEquals("IN_PROGRESS", status(c.segment()), "到料不能代替车间显式开工");
        fixture.loginAs(c.workerUser());
        var started = segments.start(c.plan(), c.segment(),
                new SegmentTransitionRequest(version(c.segment()), "default-physical-start-" + c.segment()));
        assertEquals("IN_PROGRESS", started.status());
        qty("40", db.queryForObject("SELECT COALESCE(sum(qty_base),0) FROM production_material_stock_postings WHERE demand_id=? AND posting_type='ISSUE'",
                BigDecimal.class, parentDemand(c)));
    }

    @Test
    void actualSurplusDirectTransferPreservesDemandRemainderAndApprovalIsIdempotent() {
        Case c = create("dt-actual-split", false);
        approveOverproductionRate(c.childSegment(), c.world().superAdminUserId(), "0.30");
        fixture.loginAs(c.workerUser());
        confirmRoute(c.plan(), c.segment(), "CONTINUOUS");
        receive(c, c.child(), c.leaf(), "20");
        fixture.loginAs(c.workerUser());
        segments.recheckMaterial(c.plan(), c.segment(), new SegmentTransitionRequest(
                version(c.segment()), "actual-prepare-" + c.segment()));
        var drawItems = List.of(new ProductionDrawRequest.Item(c.segment(), version(c.segment())));
        var preview = drawRequests.preview(new ProductionDrawRequest.PreviewRequest(drawItems));
        qty("20", preview.lines().getFirst().qty());
        var submitted = drawRequests.submit(new ProductionDrawRequest.SubmitRequest(
                drawItems, "actual-draw-" + c.segment(), preview.fingerprint()));
        fixture.loginAs(c.world().superAdminUserId());
        var issue = new StockDocIssueBatchRequest();
        issue.setIdempotencyKey("actual-issue-" + c.segment());
        issue.setDocIds(submitted.documentIds());
        stock.issueFullBatch(issue);
        fixture.loginAs(c.workerUser());
        segments.start(c.plan(), c.segment(), new SegmentTransitionRequest(
                version(c.segment()), "actual-parent-start-" + c.segment()));

        UUID target = parentDemand(c);
        qty("80", db.queryForObject("SELECT fn_workshop_direct_remaining_for_source(?,?)",
                BigDecimal.class, c.childSegment(), target));
        UUID reportId = createTransferDraft(c, "130", target);
        var detail = reports.detail(reportId);
        assertEquals(3, detail.getItems().size());
        var direct = detail.getItems().stream().filter(line -> "WORKSHOP".equals(line.getDestination()))
                .findFirst().orElseThrow();
        var demandWarehouse = detail.getItems().stream()
                .filter(line -> "WAREHOUSE".equals(line.getDestination()) && !line.isPublicOutput())
                .findFirst().orElseThrow();
        var surplus = detail.getItems().stream().filter(line -> line.isActualSurplus())
                .findFirst().orElseThrow();
        qty("80", direct.getQty());
        qty("20", demandWarehouse.getQty());
        qty("30", surplus.getQty());
        assertEquals("WAREHOUSE", surplus.getDestination());
        assertTrue(surplus.isPublicOutput());
        assertNull(surplus.getDirectTransferDemandId());
        assertNull(surplus.getSalesOrderItemId());
        assertNull(surplus.getExecutionSegmentSalesAllocationId());
        assertEquals(1, detail.getItems().stream().map(line -> line.getOutputBatchId()).distinct().count());
        detail.getItems().forEach(line -> qty("130", line.getOutputBatchQty()));

        var command = DailyReportApproveRequests.freshKey();
        reports.approve(reportId, command);
        reports.approve(reportId, command);
        qty("80", db.queryForObject("""
                SELECT COALESCE(sum(qty),0) FROM production_workshop_direct_transfer_items
                WHERE to_demand_id=? AND reversal_id IS NULL
                """, BigDecimal.class, target));
        assertEquals(1, db.queryForObject("""
                SELECT count(*) FROM production_workshop_direct_transfer_items
                WHERE to_demand_id=? AND reversal_id IS NULL
                """, Integer.class, target));
        qty("100", db.queryForObject("SELECT required_qty FROM production_material_demands WHERE id=?",
                BigDecimal.class, target));
        qty("100", db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE id=?",
                BigDecimal.class, c.childSegment()));
        qty("130", db.queryForObject("SELECT COALESCE(sum(qty),0) FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",
                BigDecimal.class, reportId));
        qty("0", db.queryForObject("SELECT COALESCE(sum(qty),0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",
                BigDecimal.class, c.child(), c.leaf()));
        qty("0", db.queryForObject("SELECT COALESCE(sum(qty),0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",
                BigDecimal.class, c.child(), c.lineSide()));
        assertNull(demandWarehouse.getDirectTransferDemandId());
        fixture.loginAs(c.world().superAdminUserId());
        var arrivals = beans.getBean(ProductionFinishedArrivalRegistrationService.class);
        var quality = beans.getBean(ProductionFqcInspectionService.class);
        for (var row : List.of(surplus, demandWarehouse)) {
            arrivals.register(reportId, new ArrivalRegistrationRequest("actual-dt-arrival-" + row.getId(),
                    c.leaf(), List.of(new ArrivalRegistrationItemRequest(row.getId(), "直送余量实物点收")), null));
            UUID inspection = db.queryForObject("SELECT id FROM production_fqc_inspections WHERE source_report_item_id=?",
                    UUID.class, row.getId());
            quality.decide(inspection, new DecisionRequest("PASS", row.getQty(), null, null, null,
                    "actual-dt-pass-" + row.getId()));
            UUID inbound = db.queryForObject("SELECT doc_id FROM stock_document_items WHERE source_daily_report_item_id=? AND NOT is_deleted",
                    UUID.class, row.getId());
            fixture.confirmFinishedInboundFully(inbound);
            if (row.isActualSurplus()) {
                assertEquals(0, db.queryForObject("SELECT count(*) FROM stock_reservations WHERE source_doc_type='PRODUCTION_INBOUND' AND source_doc_id=? AND NOT is_deleted",
                        Integer.class, inbound), "公共超产不能再占下工序需求");
                qty("30", db.queryForObject("SELECT COALESCE(sum(qty),0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",
                        BigDecimal.class, c.child(), c.leaf()));
            }
        }
        qty("50", db.queryForObject("SELECT COALESCE(sum(qty),0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",
                BigDecimal.class, c.child(), c.leaf()));
        qty("100", db.queryForObject("SELECT COALESCE(sum(qty_base),0) FROM production_material_stock_postings WHERE demand_id=? AND posting_type='ISSUE'",
                BigDecimal.class, target));
        qty("100", db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE id=?",
                BigDecimal.class, c.childSegment()));
    }

    @Test
    void actualSurplusCannotTurnCrossWorkshopTransferIntoPublicWarehouseOutput() {
        Case c = create("dt-actual-cross", false);
        approveOverproductionRate(c.childSegment(), c.world().superAdminUserId(), "0.30");
        fixture.loginAs(c.world().superAdminUserId());
        UUID workshop = UUID.randomUUID(), worker = UUID.randomUUID();
        db.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES(?,?,?,(SELECT id FROM departments WHERE code='DEPT_PROD'),'二级班组')",
                workshop, "W-actual-cross-other", "另一接收车间");
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')
                """, worker, "ACTUAL-CROSS-WORKER", "另一车间负责人", workshop);
        segments.assign(c.plan(), c.segment(), new SegmentAssignmentRequest(
                version(c.segment()), "actual-cross-assign-" + c.segment(),
                workshop, null, worker, BusinessTime.today(), BusinessTime.today().plusDays(10)));
        UUID target = parentDemand(c);
        fixture.loginAs(c.workerUser());
        ApiException error = assertThrows(ApiException.class, () -> {
            UUID reportId = createTransferDraft(c, "130", target);
            reports.approve(reportId, DailyReportApproveRequests.freshKey());
        });
        assertTrue(error.getMessage().contains("同车间") || error.getMessage().contains("跨车间"), error.getMessage());
        assertEquals(0, db.queryForObject("SELECT count(*) FROM production_workshop_direct_transfer_items WHERE to_demand_id=?",
                Integer.class, target));
        qty("0", db.queryForObject("SELECT fqty FROM production_plan_items WHERE id=(SELECT source_plan_item_id FROM production_execution_segments WHERE id=?)",
                BigDecimal.class, c.childSegment()));
    }

    @Test
    void actualSurplusCannotTurnUnrelatedSameGoodsTransferIntoPublicWarehouseOutput() {
        Case c = create("dt-actual-unrelated", false);
        approveOverproductionRate(c.childSegment(), c.world().superAdminUserId(), "0.30");
        fixture.loginAs(c.world().superAdminUserId());
        UUID order = fixture.createApprovedOrder(c.world(), c.parent(), "100", "100");
        UUID orderItem = db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?", UUID.class, order);
        var analysis = analyses.preview(new PreviewRequest(null, null, null, c.world().warehouseId(),
                "actual-unrelated-preview-" + order, List.of(new PreviewItem("SALES_ORDER_ITEM", orderItem,
                null, null, null, null, null, BusinessTime.today().plusDays(10), new BigDecimal("100")))));
        analyses.saveRoutes(analysis.analysisId(), new RouteRequest(analysis.version(), analysis.fingerprint(),
                "actual-unrelated-route-" + order, analysis.flatMaterials().stream()
                .map(row -> new RouteDecision(row.materialLineId(), row.actionGroupKey(), "MAKE", null)).toList()));
        analysis = analyses.detail(analysis.analysisId());
        var plan = commands.issueWorkshopPlans(analysis.analysisId(), new IssueWorkshopPlansRequest(
                analysis.version(), analysis.fingerprint(), "actual-unrelated-plan-" + order, c.world().warehouseId(),
                BusinessTime.today(), BusinessTime.today().plusDays(10), true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null, analysis.products().getFirst().analysisLineId(),
                        new BigDecimal("100"), BusinessTime.today(), BusinessTime.today().plusDays(10),
                        c.workshop(), null, c.worker(), null, null))));
        UUID target = db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND goods_id=?",
                UUID.class, plan.plans().getFirst().segmentIds().getFirst(), c.child());
        fixture.loginAs(c.workerUser());
        ApiException error = assertThrows(ApiException.class, () -> {
            UUID reportId = createTransferDraft(c, "130", target);
            reports.approve(reportId, DailyReportApproveRequests.freshKey());
        });
        assertTrue(error.getMessage().contains("责任") || error.getMessage().contains("来源"), error.getMessage());
        assertEquals(0, db.queryForObject("SELECT count(*) FROM production_workshop_direct_transfer_items WHERE to_demand_id=?",
                Integer.class, target));
        qty("0", db.queryForObject("SELECT fqty FROM production_plan_items WHERE id=(SELECT source_plan_item_id FROM production_execution_segments WHERE id=?)",
                BigDecimal.class, c.childSegment()));
    }

    // 「线边仓公共库存被无谱系任务占用→重核提升→自动投入资格拒绝」的构造依赖
    // 「先有兄弟需求、再做直送审核」，而那条直送审核会先被既有足迹守卫拦下
    //（来源集合含同货品兄弟计划，预读后变化）——即该状态在现有链路上不可达，
    // 预检（issueLineSideDrawsAfterPromotion）作为纵深防御保留，不另设测试锁定。

    // ===================== 夹具 =====================

    @Test
    void actualSurplusPublicFirstDoesNotAdvanceRootNestedOrMrpPlanProgress() {
        for (boolean nested : List.of(false, true)) {
            String tag = nested ? "dt-progress-child" : "dt-progress-root";
            var world = fixture.seedWorld(tag);
            fixture.loginAs(world.superAdminUserId());
            UUID product = UUID.randomUUID();
            fixture.insertGoods(product, "P-" + tag, "进度测试自制件", "自制", world.unitId(), world.unitLegacy());
            fixture.insertBom(product, world.goodsD(), "1");
            db.update("UPDATE goods_bom_items SET hard_gate=false WHERE goods_id=?", product);
            UUID rootProduct = product;
            if (nested) {
                rootProduct = UUID.randomUUID();
                fixture.insertGoods(rootProduct, "ROOT-" + tag, "进度测试上层件", "自制", world.unitId(), world.unitLegacy());
                fixture.insertBom(rootProduct, product, "1");
            }
            UUID rootPlan = org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                    fixture, "approvedPlan", world, rootProduct, "100", "100");
            var packages = beans.getBean(ProductionPlanningPackageService.class);
            var preview = packages.preview(rootPlan, world.warehouseId());
            var generate = new GeneratePlanningPackageRequest();
            generate.setWarehouseId(world.warehouseId());
            generate.setIdempotencyKey("actual-progress-package-" + rootPlan);
            generate.setPreviewFingerprint(preview.fingerprint());
            generate.setGeneratePurchaseRequest(true);
            beans.getBean(BottomUpPlanOrchestrator.class).confirmFullTree(rootPlan, generate);
            UUID plan = nested ? db.queryForObject("SELECT subplan_id FROM subplan_links WHERE plan_id=? AND NOT is_deleted",
                    UUID.class, rootPlan) : rootPlan;
            UUID segment = db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",
                    UUID.class, plan);
            fixture.confirmFullKitRoute(plan, segment);
            segments.start(plan, segment, new SegmentTransitionRequest(version(segment), "actual-progress-start-" + segment));
            approveOverproductionRate(segment, world.superAdminUserId(), "0.30");
            var source = beans.getBean(ReportablePlanLineQueryService.class).list(1, 50, null, null, List.of(segment))
                    .getItems().getFirst();
            var command = new DailyReportSaveRequest();
            command.setIdempotencyKey("actual-progress-report-" + segment);
            command.setBillDate(BusinessTime.today());
            command.setDepartmentId(db.queryForObject("SELECT workshop_department_id FROM production_execution_segments WHERE id=?", UUID.class, segment));
            command.setWorkerIds(List.of(db.queryForObject("SELECT responsible_employee_id FROM production_execution_segments WHERE id=?", UUID.class, segment)));
            var line = new DailyReportItemLine();
            line.setPlanItemId(source.planItemId());
            line.setExecutionSegmentId(segment);
            line.setExecutionSegmentSalesAllocationId(source.executionSegmentSalesAllocationId());
            line.setSalesOrderItemId(source.orderItemId());
            line.setGoodsId(product);
            line.setUnitId(world.unitId());
            line.setUnitRate(BigDecimal.ONE);
            line.setQty(new BigDecimal("130"));
            command.setItems(List.of(line));
            UUID report = reports.approve(reports.create(command).getId(), DailyReportApproveRequests.freshKey()).getId();
            var surplus = reports.detail(report).getItems().stream().filter(item -> item.isActualSurplus()).findFirst().orElseThrow();
            beans.getBean(ProductionFinishedArrivalRegistrationService.class).register(report,
                    new ArrivalRegistrationRequest("actual-progress-arrival-" + report, world.warehouseId(),
                            List.of(new ArrivalRegistrationItemRequest(surplus.getId(), "超产先入库")), null));
            UUID inspection = db.queryForObject("SELECT id FROM production_fqc_inspections WHERE source_report_item_id=?", UUID.class, surplus.getId());
            beans.getBean(ProductionFqcInspectionService.class).decide(inspection,
                    new DecisionRequest("PASS", surplus.getQty(), null, null, null, "actual-progress-pass-" + report));
            UUID inbound = db.queryForObject("SELECT doc_id FROM stock_document_items WHERE source_daily_report_item_id=? AND NOT is_deleted",
                    UUID.class, surplus.getId());
            fixture.confirmFinishedInboundFully(inbound);
            qty("0", db.queryForObject("SELECT fn_plan_original_inbound_qty(?)", BigDecimal.class, source.planItemId()));
            var segmentView = segments.list(plan).stream().filter(item -> item.id().equals(segment)).findFirst().orElseThrow();
            qty("30", segmentView.inboundQty());
            qty("0", segmentView.plannedInboundQty());
            qty("30", segmentView.actualSurplusInboundQty());
            var root = beans.getBean(ProductionPlanService.class).progress(false, "progress", 1, 100, null, null, null, null)
                    .getItems().stream().filter(item -> item.planId().equals(rootPlan)).findFirst().orElseThrow();
            assertEquals(0.0, root.percent());
            assertFalse(root.closed());
            if (nested) {
                var child = root.subplans().stream().filter(item -> item.planId().equals(plan)).findFirst().orElseThrow();
                qty("30", child.inboundQty()); qty("0", child.plannedInboundQty()); qty("30", child.actualSurplusInboundQty());
                assertEquals(0.0, child.percent()); assertFalse(child.closed());
                var mrp = beans.getBean(MrpService.class).subplans(rootPlan).stream().filter(item -> item.planId().equals(plan)).findFirst().orElseThrow();
                qty("30", mrp.inboundQty()); qty("0", mrp.plannedInboundQty()); qty("30", mrp.actualSurplusInboundQty());
                assertEquals(0.0, mrp.percent()); assertFalse(mrp.closed());
            } else {
                qty("30", root.inboundQty()); qty("0", root.plannedInboundQty()); qty("30", root.actualSurplusInboundQty());
            }
        }
    }

    private record Case(
            FullChainEndToEndTest.World world,
            UUID parent, UUID child, UUID secondMaterial,
            UUID plan, UUID segment,
            UUID childPlan, UUID childSegment,
            UUID workshop, UUID worker, UUID workerUser,
            UUID leaf, UUID lineSide) {
    }

    private void approveOverproductionRate(UUID segment, UUID administrator, String rate) {
        fixture.loginAs(administrator);
        var service = beans.getBean(com.uten.imp.features.production.execution.ProductionOverproductionRateService.class);
        var context = service.context(segment);
        var request = service.submit(new com.uten.imp.features.production.execution.ProductionOverproductionRateContracts.SubmitRequest(
                segment, context.rateVersion(), new BigDecimal(rate), "回归验证已批准的实际生产容差", "rate-request-" + segment));
        service.decide(request.id(), new com.uten.imp.features.production.execution.ProductionOverproductionRateContracts.DecisionRequest(
                request.rowVersion(), "rate-approve-" + segment, "计划部批准此批容差"), true);
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
        reports.approve(createTransferDraft(c, quantity, parentDemand(c)), DailyReportApproveRequests.freshKey());
    }

    private UUID createTransferDraft(Case c, String quantity, UUID targetDemand) {
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
        item.setDirectTransferDemandId(targetDemand);
        report.setItems(List.of(item));
        return reports.create(report).getId();
    }

    private record TriggerProfile(ProductionJdbcMeasurement.Sample sample, java.util.Map<String, Long> calls,
                                  long triggerCalls, long deferredCheckCalls, String top) {}

    /** 触发器函数调用次数快照：只取返回 trigger 的函数，按函数名汇总，不含任何参数或业务值。 */
    private java.util.Map<String, Long> triggerFunctionCalls() {
        db.execute("SELECT pg_stat_clear_snapshot()");
        java.util.Map<String, Long> result = new java.util.TreeMap<>();
        db.query("""
                SELECT p.proname, SUM(s.calls) AS calls
                FROM pg_stat_user_functions s JOIN pg_proc p ON p.oid = s.funcid
                WHERE s.schemaname = 'public' AND p.prorettype = 'trigger'::regtype
                GROUP BY p.proname
                """, rs -> { result.put(rs.getString(1), rs.getLong(2)); });
        return result;
    }

    /** 同 {@link #measureTransferApprove}，另在同一笔审核事务里打开 track_functions 统计触发器调用。 */
    private TriggerProfile profileTransferApprove(Case c, String quantity) throws InterruptedException {
        fixture.loginAs(c.workerUser());
        var report = new DailyReportSaveRequest();
        report.setIdempotencyKey("dt-trigger-probe-" + c.segment() + "-" + quantity);
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
        var before = triggerFunctionCalls();
        ProductionJdbcMeasurement.Sample sample = ProductionJdbcMeasurement.begin();
        try {
            new org.springframework.transaction.support.TransactionTemplate(transactionManager)
                    .executeWithoutResult(status -> {
                        // 只对这一笔真实审核事务计数，提交时 SET LOCAL 随事务结束。
                        db.execute("SET LOCAL track_functions = 'all'");
                        db.execute("SELECT pg_stat_force_next_flush()");
                        reports.approve(reportId, DailyReportApproveRequests.freshKey());
                    });
        } finally {
            ProductionJdbcMeasurement.end();
        }
        java.util.Map<String, Long> delta = new java.util.TreeMap<>();
        for (int attempt = 0; attempt < 30 && delta.isEmpty(); attempt++) {
            Thread.sleep(100);
            var after = triggerFunctionCalls();
            after.forEach((name, calls) -> {
                long diff = calls - before.getOrDefault(name, 0L);
                if (diff > 0) delta.put(name, diff);
            });
        }
        assertFalse(delta.isEmpty(), "被测事务必须产生真实的 PostgreSQL 函数计数");
        long total = delta.values().stream().mapToLong(Long::longValue).sum();
        long deferred = delta.entrySet().stream()
                .filter(entry -> entry.getKey().startsWith("fn_check_") || entry.getKey().startsWith("fn_validate_")
                        || entry.getKey().startsWith("fn_assert_"))
                .mapToLong(java.util.Map.Entry::getValue).sum();
        String top = delta.entrySet().stream()
                .sorted((a, b) -> Long.compare(b.getValue(), a.getValue()))
                .map(entry -> entry.getKey() + "=" + entry.getValue())
                .collect(java.util.stream.Collectors.joining(","));
        return new TriggerProfile(sample, delta, total, deferred, top);
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
