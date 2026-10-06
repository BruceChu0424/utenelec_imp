package com.uten.imp.businesschain;

import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.plan.dto.PlanBatchResult;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
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
import java.time.LocalDate;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.AnalysisView;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.GeneratedPlan;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.IssueWorkshopPlansRequest;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

/**
 * 生产计划「批量审核」的预锁覆盖(与仓库到货批量登记同一类缺陷, 2026-10-06 普查)。
 *
 * <p>批量审核在一个事务里逐张走单张审核, 每张各自 {@code lockPlan} 取预锁; 事务里第一次取锁的那张
 * 成了整个事务的「完整预锁集合」, 后面几张只做内存覆盖检查。计划带着物料分析下达时存下的预排草案,
 * 审核会原子下达(建计划包、锁分析物料库存维度): 第二张计划的物料维度不在第一张的预锁里,
 * 库存锁入口按「预锁后变化」拒绝, 整批回滚。单张审核同一张计划是通的(对照用例)。</p>
 *
 * <p>生产配置(不开嵌套足迹诊断), 断言的是用户真实看到的结果。修复(ADR-107 第六节): 批量审核先按
 * {@code beginPlanBatch} 对全部要办的计划合并预锁, 再逐张走单张内核。</p>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000",
        // 测试类路径默认打开嵌套足迹诊断(src/test/resources/config/application.yml), 这里按生产配置关掉。
        "uten.concurrency.verify-nested-footprint=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionPlanBatchPrelockCoverageEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionPlanService plans;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService analysisCommands;
    FullChainEndToEndTest fixture;

    @BeforeEach
    void setup() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
    }

    /** 对照: 单张审核带预排草案的分析计划, 同事务原子下达出一张已确认的计划包。 */
    @Test
    void singleApproveAppliesTheSavedPlanningDraft() {
        var world = fixture.seedWorld("bpc-plan-one-" + suffix());
        UUID plan = draftAnalysisPlan(world);
        fixture.loginAs(world.superAdminUserId());

        plans.approve(plan);

        assertEquals(1, status(plan));
        assertEquals(1, confirmedPackages(plan));
    }

    /**
     * 两张互不相干(不同订单、不同货品、不同仓)的分析计划一起批量审核, 应与逐张审核结果一致:
     * 两张都审核通过、各自下达出计划包。
     */
    @Test
    void batchApproveAppliesEveryPlanningDraftWhenThePlansShareNothing() {
        var first = fixture.seedWorld("bpc-plan-a-" + suffix());
        var second = fixture.seedWorld("bpc-plan-b-" + suffix());
        UUID firstPlan = draftAnalysisPlan(first);
        UUID secondPlan = draftAnalysisPlan(second);
        fixture.loginAs(first.superAdminUserId());

        PlanBatchResult result = assertDoesNotThrow(
                () -> plans.batchApprove(List.of(firstPlan, secondPlan)),
                "批量审核两张不相干的计划应与逐张审核一样成功");

        assertEquals(Set.of(firstPlan, secondPlan), result.done().stream()
                .map(PlanBatchResult.Done::id).collect(Collectors.toSet()));
        assertEquals(1, status(firstPlan));
        assertEquals(1, status(secondPlan));
        assertEquals(1, confirmedPackages(firstPlan));
        assertEquals(1, confirmedPackages(secondPlan));
    }

    /** 物料分析下达车间(不立即审核): 得到一张带预排草案的草稿计划。 */
    private UUID draftAnalysisPlan(FullChainEndToEndTest.World world) {
        // 半成品 B 与委外件 E 现货足够, 只剩顶层自制要确认路线(与既有分析下达用例同一形态)。
        db.update("INSERT INTO stock_balances(warehouse_id, goods_id, color_id, qty) VALUES (?,?,NULL,?)",
                world.warehouseId(), world.goodsB(), new BigDecimal("20"));
        db.update("INSERT INTO stock_balances(warehouse_id, goods_id, color_id, qty) VALUES (?,?,NULL,?)",
                world.warehouseId(), world.goodsE(), new BigDecimal("10"));
        UUID order = fixture.createApprovedOrder(world, world.goodsA(), "10", "100");
        UUID orderItem = db.queryForObject(
                "SELECT id FROM sales_order_items WHERE order_id = ?", UUID.class, order);
        fixture.loginAs(world.superAdminUserId());
        AnalysisView view = analyses.preview(new PreviewRequest(
                null, null, null, world.warehouseId(), "bpc-preview-" + orderItem,
                List.of(new PreviewItem("SALES_ORDER_ITEM", orderItem, null, null, null,
                        null, null, LocalDate.of(2026, 9, 1), new BigDecimal("10")))));
        UUID analysisId = view.analysisId();
        UUID productLine = view.products().getFirst().analysisLineId();
        ReflectionTestUtils.invokeMethod(fixture, "confirmRootMakeRoute", analysisId, analyses.detail(analysisId));
        AnalysisView routed = analyses.detail(analysisId);
        GeneratedPlan plan = analysisCommands.issueWorkshopPlans(analysisId, new IssueWorkshopPlansRequest(
                routed.version(), routed.fingerprint(), "bpc-generate-" + analysisId,
                world.warehouseId(), LocalDate.of(2026, 8, 8), null, false,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(
                        null, productLine, new BigDecimal("10"), null, null, null, null, null, null, null))))
                .plans().getFirst();
        assertEquals("DRAFT", plan.status());
        assertNotNull(plan.planningDraftId(), "不立即审核时保存预排草案, 审核时原子下达");
        return plan.planId();
    }

    private int status(UUID plan) {
        return db.queryForObject("SELECT status FROM production_plans WHERE id = ?", Integer.class, plan);
    }

    private int confirmedPackages(UUID plan) {
        return db.queryForObject("""
                SELECT count(*) FROM production_planning_packages
                WHERE plan_id = ? AND status = 'CONFIRMED' AND NOT is_deleted
                """, Integer.class, plan);
    }

    private static String suffix() {
        return UUID.randomUUID().toString().substring(0, 8);
    }
}
