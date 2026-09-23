package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.order.SalesOrderTimelineService;
import com.uten.imp.features.sales.order.dto.OrderProgressTimelineEvent;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
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

import java.lang.reflect.Method;
import java.sql.Timestamp;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * ADR-105 (db-schema-02): 审核/红冲/驳回时间由命令写在单据自己的列上, 销售订单进度时间线读列,
 * 不再从审计日志反查(审计有保留期、只存变化键, 不能当业务事实源)。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class DocumentTransitionTimeEndToEndTest {

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SalesOrderService sales;
    @Autowired ProductionPlanService plans;
    @Autowired SalesOrderTimelineService timeline;
    @Autowired SalesShipmentService shipments;
    private FullChainEndToEndTest fixture;

    @BeforeEach
    void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void clear() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void salesOrderApprovalAndReversalTimesComeFromTheOrderColumns() {
        FullChainEndToEndTest.World world = fixture.seedWorld("tt-order");
        UUID order = fixture.createApprovedOrder(world, world.goodsA(), "10", "100");

        OffsetDateTime approvedAt = column("sales_orders", "approved_at", order);
        assertNotNull(approvedAt, "approve writes approved_at in the same transaction");
        assertEquals(approvedAt.toInstant(), event(order, "ORDER_APPROVED").occurredAt().toInstant());

        fixture.loginAs(world.superAdminUserId());
        sales.reverse(order);
        OffsetDateTime reversedAt = column("sales_orders", "reversed_at", order);
        assertNotNull(reversedAt);
        assertNotNull(db.queryForObject("SELECT reversed_by FROM sales_orders WHERE id=?", UUID.class, order),
                "the reversing employee is kept on the order");
        OrderProgressTimelineEvent reversed = event(order, "ORDER_REVERSED");
        assertEquals(reversedAt.toInstant(), reversed.occurredAt().toInstant());
        assertTrue(!reversedAt.isBefore(approvedAt));
    }

    @Test
    void productionPlanApprovalAndReversalTimesComeFromThePlanColumns() throws Exception {
        FullChainEndToEndTest.World world = fixture.seedWorld("tt-plan");
        Method approvedPlan = FullChainEndToEndTest.class.getDeclaredMethod(
                "approvedPlan", FullChainEndToEndTest.World.class, UUID.class, String.class, String.class);
        approvedPlan.setAccessible(true);
        UUID plan = (UUID) approvedPlan.invoke(fixture, world, world.goodsA(), "10", "4");
        UUID order = db.queryForObject("""
                SELECT i.order_id FROM plan_order_item_links l
                JOIN production_plan_items pi ON pi.id = l.plan_item_id
                JOIN sales_order_items i ON i.id = l.order_item_id
                WHERE pi.plan_id = ? AND NOT l.is_deleted LIMIT 1
                """, UUID.class, plan);

        OffsetDateTime approvedAt = column("production_plans", "approved_at", plan);
        assertNotNull(approvedAt);
        List<OrderProgressTimelineEvent> planEvents = timeline.timeline(order).stream()
                .filter(event -> "PRODUCTION_PLAN".equals(event.code()) && plan.equals(event.docId()))
                .toList();
        assertEquals(1, planEvents.size());
        assertEquals(approvedAt.toInstant(), planEvents.getFirst().occurredAt().toInstant());

        fixture.loginAs(world.superAdminUserId());
        plans.reverse(plan);
        assertNotNull(column("production_plans", "reversed_at", plan));
        assertNotNull(db.queryForObject("SELECT reversed_by FROM production_plans WHERE id=?", UUID.class, plan));
    }

    @Test
    void shipmentOutboundAndWarehouseRejectionTimesComeFromTheShipmentColumns() {
        FullChainEndToEndTest.World world = fixture.seedWorld("tt-ship");
        fixture.loginAs(world.superAdminUserId());
        ReflectionTestUtils.invokeMethod(fixture, "putDirectTargetStock", world, world.goodsE(), "10");
        UUID order = fixture.createApprovedOrder(world, world.goodsE(), "10", "100");
        UUID orderItem = db.queryForObject(
                "SELECT id FROM sales_order_items WHERE order_id = ?", UUID.class, order);
        UUID operator = db.queryForObject(
                "SELECT employee_id FROM users WHERE id = ?", UUID.class, world.superAdminUserId());

        // 仓库确认出库 = 出货单审核: 同一事务写 approved_at, 时间线的「仓库已发货」读它。
        UUID shipped = fixture.createShipment(world, orderItem, world.goodsE(), "4");
        fixture.shipThroughWarehouse(shipped);
        OffsetDateTime approvedAt = column("sales_shipments", "approved_at", shipped);
        assertNotNull(approvedAt, "warehouse outbound writes approved_at in the same transaction");
        assertEquals(approvedAt.toInstant(),
                shipmentEvent(order, shipped, "SHIPMENT_SHIPPED").occurredAt().toInstant());

        // 仓库驳回草稿: 驳回时间与驳回人落在出货单上, 时间线带出时间和驳回人。
        UUID rejected = fixture.createShipment(world, orderItem, world.goodsE(), "3");
        shipments.reject(rejected, "仓库备货异常");
        OffsetDateTime rejectedAt = column("sales_shipments", "rejected_at", rejected);
        assertNotNull(rejectedAt);
        assertEquals(operator, db.queryForObject(
                "SELECT rejected_by FROM sales_shipments WHERE id = ?", UUID.class, rejected));
        OrderProgressTimelineEvent rejection = shipmentEvent(order, rejected, "SHIPMENT_WAREHOUSE_REJECTED");
        assertEquals(rejectedAt.toInstant(), rejection.occurredAt().toInstant());
        assertNotNull(rejection.operatorName(), "the rejecting employee is named on the timeline");

        // 已出库的货只能走销售退货; 直接红冲被拒, 红冲列保持为空(红冲命令只在允许的路径上写 reversed_at/by)。
        assertThrows(ApiException.class, () -> shipments.reverse(shipped));
        assertNull(column("sales_shipments", "reversed_at", shipped));
        assertNull(db.queryForObject("SELECT reversed_by FROM sales_shipments WHERE id = ?", UUID.class, shipped));
    }

    private OrderProgressTimelineEvent shipmentEvent(UUID order, UUID shipment, String code) {
        return timeline.timeline(order).stream()
                .filter(event -> code.equals(event.code()) && shipment.equals(event.docId()))
                .findFirst()
                .orElseThrow(() -> new AssertionError("missing timeline event " + code + " for " + shipment));
    }

    private OrderProgressTimelineEvent event(UUID order, String code) {
        return timeline.timeline(order).stream()
                .filter(event -> code.equals(event.code()))
                .findFirst()
                .orElseThrow(() -> new AssertionError("missing timeline event " + code));
    }

    private OffsetDateTime column(String table, String column, UUID id) {
        Timestamp value = db.queryForObject(
                "SELECT " + column + " FROM " + table + " WHERE id = ?", Timestamp.class, id);
        return value == null ? null : value.toInstant().atOffset(java.time.ZoneOffset.UTC);
    }
}
