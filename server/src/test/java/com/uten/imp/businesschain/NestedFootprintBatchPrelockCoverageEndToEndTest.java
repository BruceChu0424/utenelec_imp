package com.uten.imp.businesschain;

import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.plan.dto.PlanBatchResult;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.sales.shipment.dto.ShipmentFinanceBatchDecisionRequest;
import com.uten.imp.features.sales.shipment.dto.ShipmentFinanceDecisionRequest;
import com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest;
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

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 批量命令的预锁覆盖, 用嵌套足迹诊断开关({@code uten.concurrency.verify-nested-footprint=true})暴露
 * (与仓库到货批量登记同一类缺陷, 2026-10-06 普查)。
 *
 * <p>这几个批量入口在一个事务里逐项调用单项命令, 每项各自取预锁: 第一项的足迹成了整个事务的
 * 「完整预锁集合」, 后面各项的商业来源/库存维度没有预锁就写了(销售订单行回写、出货单放行锁订单行)。
 * 生产配置下嵌套取锁只比调用方声明的已知 id, 这几处声明为空, 所以不报错, 但锁序已被破坏;
 * 打开诊断开关后, 嵌套取锁会重跑本项的发现并要求落在预锁集合内, 缺口直接显形。
 * 每个缺陷用例都配一个同配置下的单项对照, 证明单项本身在诊断下是干净的。</p>
 *
 * <p>修复(ADR-107 第六节): 计划批量审核/删除先 {@code beginPlanBatch}、出货财务批量放行/退回先 {@code lockShipments},
 * 在写任何一项之前把全部项的足迹合成一次预锁。</p>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000",
        "uten.concurrency.verify-nested-footprint=true",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class NestedFootprintBatchPrelockCoverageEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionPlanService plans;
    @Autowired SalesShipmentService shipments;
    @Autowired TaskClaimService claims;
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

    // ------------------------------------------------------------------ 生产计划批量审核 / 批量删除

    /** 对照: 只含一张计划的批量审核与批量删除, 诊断下照常通过。 */
    @Test
    void planBatchOfOneIsCleanUnderNestedFootprintDiagnostics() {
        var world = fixture.seedWorld("bpc-nf-plan-one-" + suffix());
        UUID approved = legacyDraftPlan(world);
        UUID deleted = legacyDraftPlan(world);
        fixture.loginAs(world.superAdminUserId());

        assertEquals(List.of(approved), doneIds(plans.batchApprove(List.of(approved))));
        assertEquals(List.of(deleted), doneIds(plans.batchDelete(List.of(deleted))));
        assertEquals(1, planStatus(approved));
        assertTrue(planDeleted(deleted));
    }

    /** 两张不相干计划(不同订单、不同货品)批量审核: 第二张的销售来源与库存维度不在预锁里。 */
    @Test
    void planBatchApproveCoversEveryPlanFootprint() {
        var first = fixture.seedWorld("bpc-nf-plan-a-" + suffix());
        var second = fixture.seedWorld("bpc-nf-plan-b-" + suffix());
        UUID firstPlan = legacyDraftPlan(first);
        UUID secondPlan = legacyDraftPlan(second);
        fixture.loginAs(first.superAdminUserId());

        PlanBatchResult result = assertDoesNotThrow(
                () -> plans.batchApprove(List.of(firstPlan, secondPlan)),
                "批量审核的预锁应覆盖每一张计划的足迹");

        assertEquals(Set.of(firstPlan, secondPlan), Set.copyOf(doneIds(result)));
        assertEquals(1, planStatus(firstPlan));
        assertEquals(1, planStatus(secondPlan));
    }

    /** 两张不相干草稿计划批量删除: 同样只有第一张取到了完整预锁。 */
    @Test
    void planBatchDeleteCoversEveryPlanFootprint() {
        var first = fixture.seedWorld("bpc-nf-del-a-" + suffix());
        var second = fixture.seedWorld("bpc-nf-del-b-" + suffix());
        UUID firstPlan = legacyDraftPlan(first);
        UUID secondPlan = legacyDraftPlan(second);
        fixture.loginAs(first.superAdminUserId());

        PlanBatchResult result = assertDoesNotThrow(
                () -> plans.batchDelete(List.of(firstPlan, secondPlan)),
                "批量删除的预锁应覆盖每一张计划的足迹");

        assertEquals(Set.of(firstPlan, secondPlan), Set.copyOf(doneIds(result)));
        assertTrue(planDeleted(firstPlan));
        assertTrue(planDeleted(secondPlan));
    }

    // ------------------------------------------------------------------ 销售出货财务批量放行 / 批量退回

    /** 对照: 单张财务放行在诊断下照常通过。 */
    @Test
    void singleShipmentFinanceReleaseIsCleanUnderNestedFootprintDiagnostics() {
        var world = fixture.seedWorld("bpc-nf-ship-one-" + suffix());
        UUID shipment = draftShipment(world);
        fixture.loginAs(world.superAdminUserId());
        var item = financeItem(shipment);

        shipments.financeAudit(shipment, new ShipmentFinanceDecisionRequest(
                item.expectedRevision(), item.expectedContentHash(), item.expectedClaimId(), null));

        assertEquals(1, financeAudit(shipment));
    }

    /** 两张不相干出货单(不同客户订单、不同货品)批量放行: 第二张的来源订单没有预锁就被锁行写入。 */
    @Test
    void shipmentFinanceBatchReleaseCoversEveryShipmentFootprint() {
        var first = fixture.seedWorld("bpc-nf-ship-a-" + suffix());
        var second = fixture.seedWorld("bpc-nf-ship-b-" + suffix());
        UUID firstShipment = draftShipment(first);
        UUID secondShipment = draftShipment(second);
        fixture.loginAs(first.superAdminUserId());
        var items = List.of(financeItem(firstShipment), financeItem(secondShipment));

        assertDoesNotThrow(() -> shipments.financeAuditBatch(new ShipmentFinanceBatchDecisionRequest(items, null)),
                "财务批量放行的预锁应覆盖每一张出货单的足迹");

        assertEquals(1, financeAudit(firstShipment));
        assertEquals(1, financeAudit(secondShipment));
    }

    /** 两张不相干出货单批量退回: 与批量放行同一形态。 */
    @Test
    void shipmentFinanceBatchRejectCoversEveryShipmentFootprint() {
        var first = fixture.seedWorld("bpc-nf-rej-a-" + suffix());
        var second = fixture.seedWorld("bpc-nf-rej-b-" + suffix());
        UUID firstShipment = draftShipment(first);
        UUID secondShipment = draftShipment(second);
        fixture.loginAs(first.superAdminUserId());
        var items = List.of(financeItem(firstShipment), financeItem(secondShipment));

        assertDoesNotThrow(() -> shipments.financeAuditRejectBatch(
                        new ShipmentFinanceBatchDecisionRequest(items, "客户资料待核对，请销售补齐后重新提交")),
                "财务批量退回的预锁应覆盖每一张出货单的足迹");

        assertTrue(financeRejected(firstShipment));
        assertTrue(financeRejected(secondShipment));
    }

    // ------------------------------------------------------------------ 数据准备

    private UUID legacyDraftPlan(FullChainEndToEndTest.World world) {
        UUID order = fixture.createApprovedOrder(world, world.goodsA(), "30", "100");
        UUID orderItem = db.queryForObject(
                "SELECT id FROM sales_order_items WHERE order_id = ?", UUID.class, order);
        fixture.loginAs(world.superAdminUserId());
        UUID plan = ReflectionTestUtils.invokeMethod(fixture, "createLegacyTestDraft", orderItem, world.goodsA(), "3");
        assertNotNull(plan);
        return plan;
    }

    private UUID draftShipment(FullChainEndToEndTest.World world) {
        ReflectionTestUtils.invokeMethod(fixture, "putDirectTargetStock", world, world.goodsE(), "10");
        UUID order = fixture.createApprovedOrder(world, world.goodsE(), "10", "100");
        UUID orderItem = db.queryForObject(
                "SELECT id FROM sales_order_items WHERE order_id = ?", UUID.class, order);
        ShipmentSaveRequest request = ReflectionTestUtils.invokeMethod(
                fixture, "shipmentRequest", world, orderItem, world.goodsE(), "10");
        assertNotNull(request);
        return shipments.create(request).getId();
    }

    /** 当前登录人认领并读取核对信息: 批量请求里每一项带上所见的版本、内容哈希与认领。 */
    private ShipmentFinanceBatchDecisionRequest.Item financeItem(UUID shipment) {
        var claim = claims.claim("SALES_SHIPMENT_FINANCE_AUDIT", shipment.toString());
        Map<String, Object> info = shipments.financeAuditInfo(shipment);
        return new ShipmentFinanceBatchDecisionRequest.Item(shipment,
                ((Number) info.get("reviewRevision")).longValue(), info.get("contentHash").toString(), claim.claimId());
    }

    private static List<UUID> doneIds(PlanBatchResult result) {
        return result.done().stream().map(PlanBatchResult.Done::id).collect(Collectors.toList());
    }

    private int planStatus(UUID plan) {
        return db.queryForObject("SELECT status FROM production_plans WHERE id = ?", Integer.class, plan);
    }

    private boolean planDeleted(UUID plan) {
        return Boolean.TRUE.equals(db.queryForObject(
                "SELECT is_deleted FROM production_plans WHERE id = ?", Boolean.class, plan));
    }

    private int financeAudit(UUID shipment) {
        return db.queryForObject("SELECT finance_audit FROM sales_shipments WHERE id = ?", Integer.class, shipment);
    }

    private boolean financeRejected(UUID shipment) {
        return Boolean.TRUE.equals(db.queryForObject(
                "SELECT finance_rejected FROM sales_shipments WHERE id = ?", Boolean.class, shipment));
    }

    private static String suffix() {
        return UUID.randomUUID().toString().substring(0, 8);
    }
}
