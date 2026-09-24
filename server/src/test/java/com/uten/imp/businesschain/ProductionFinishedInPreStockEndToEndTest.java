package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.quality.ProductionFqcContracts.DecisionRequest;
import com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchRequest;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationItemRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 自制产成品「先入库后质检」(V597 / ADR-090 第六节)全链路。
 *
 * <p>语义与采购/委外那条链(V596)不同的地方在于实物流：送检登记本身就是实物交到成品仓库位
 * 的那一刻，所以这条链上的「先入库后质检」= 登记时就承诺「品质合格按这个位置全量入库」。
 * 本测试验证：登记只记决定不写库存；合格在判定的同一事务里按登记位置自动点收(确认行
 * origin=PRE_STOCKED_AUTO、单据直接到已审核、仓库不再有待点收任务)；不合格一个字节库存都不动；
 * 批量全部合格同样逐单落库(预锁集合一次拿全，回调不补拿上游目标)；自动点收这条通道
 * 只认「先入库后质检」的登记证据，别的成品入库单借不到。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000"})
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = ProductionFinishedInPreStockEndToEndTest.Cleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class ProductionFinishedInPreStockEndToEndTest {
    private static final PostgreSQLContainer<?> DATABASE = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final String SECRET = UUID.randomUUID() + "-" + UUID.randomUUID();

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry properties) {
        DATABASE.start();
        properties.add("spring.datasource.url", DATABASE::getJdbcUrl);
        properties.add("spring.datasource.username", DATABASE::getUsername);
        properties.add("spring.datasource.password", DATABASE::getPassword);
        properties.add("uten.jwt.secret", () -> SECRET);
        properties.add("uten.crypto.pgp-master-key", () -> SECRET);
        properties.add("uten.crypto.hmac-key", () -> SECRET);
        properties.add("uten.bootstrap.admin-login", () -> "fqc-prestock-bootstrap");
        properties.add("uten.bootstrap.admin-password", () -> SECRET + "Aa1!");
    }

    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder() - 1; }
        @Override public void afterTestClass(TestContext ignored) { DATABASE.stop(); }
    }

    @Autowired JdbcTemplate jdbc;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ProductionFinishedArrivalRegistrationService arrivals;
    @Autowired ProductionFqcInspectionService quality;
    @Autowired StockDocService stockDocs;

    @AfterEach
    void cleanup() { SecurityContextHolder.clearContext(); }

    // ------------------------------------------------------------------ 合格自动点收 / 不合格不动库存

    @Test
    void preStockedRegistrationPostsStockOnPassAndLeavesStockUntouchedOnFail() {
        Case c = prepare("fip-pass", true, "3", "4");

        // ① 登记只记下「合格自动点收」这个决定：三列同进同出，库存与入库单都还不存在。
        Map<String, Object> header = jdbc.queryForMap("""
                SELECT stock_in_before_inspection, pre_stocked_at, pre_stocked_by_employee_id, warehouse_id
                FROM production_finished_arrival_registrations WHERE source_report_id = ?
                """, c.reportId());
        assertEquals(Boolean.TRUE, header.get("stock_in_before_inspection"));
        assertNotNull(header.get("pre_stocked_at"));
        assertNotNull(header.get("pre_stocked_by_employee_id"));
        assertEquals(c.warehouseId(), header.get("warehouse_id"));
        assertEquals(0, balance(c.warehouseId(), c.goodsId()).signum(), "登记不写库存");
        assertEquals(0, finishedInDocs(c.reportId(), null), "登记不产生入库单");

        // ② 第一行合格：同一笔事务里按登记的成品仓 + 库位自动点收 —— 库存进账、
        //    确认行 origin=PRE_STOCKED_AUTO 且全量接收、入库单直接到已审核(仓库没有待点收任务)。
        quality.decide(c.inspections().getFirst(), new DecisionRequest(
                "PASS", null, null, null, "先入库后检合格", "fip-pass-one-" + c.inspections().getFirst()));
        assertEquals(0, new BigDecimal("3").compareTo(balance(c.warehouseId(), c.goodsId())),
                "合格量按登记的成品仓进库存");
        Map<String, Object> confirmation = jdbc.queryForMap("""
                SELECT confirmation.origin, confirmation.decision, confirmation.residual_stock_document_id,
                       document.status, document.warehouse_id, item.place, item.qty
                FROM production_finished_in_confirmations confirmation
                JOIN stock_documents document ON document.id = confirmation.stock_document_id
                JOIN stock_document_items item ON item.doc_id = document.id
                WHERE document.source_daily_report_id = ?
                """, c.reportId());
        assertEquals("PRE_STOCKED_AUTO", confirmation.get("origin"));
        assertEquals("ACCEPTED", confirmation.get("decision"));
        assertEquals(null, confirmation.get("residual_stock_document_id"), "自动点收没有短收余量单");
        assertEquals(1, ((Number) confirmation.get("status")).intValue(), "入库单在同一事务里已审核");
        assertEquals(c.warehouseId(), confirmation.get("warehouse_id"));
        assertEquals(c.places().getFirst(), confirmation.get("place"), "落在登记时的库位");
        assertEquals(0, finishedInDocs(c.reportId(), 0), "仓库不再收到待点收任务");
        assertEquals("RESOLVED", jdbc.queryForObject(
                "SELECT status FROM production_fqc_inspections WHERE id = ?", String.class, c.inspections().getFirst()));

        // ③ 第二行不合格：库存一个字节不动，也没有第二张确认行；恢复链路照常开授权。
        quality.decide(c.inspections().get(1), new DecisionRequest(
                "FAIL", null, new BigDecimal("4"), "REWORK", "外观不良返工", "fip-fail-" + c.inspections().get(1)));
        assertEquals(0, new BigDecimal("3").compareTo(balance(c.warehouseId(), c.goodsId())),
                "不合格不进库存");
        assertEquals(1, jdbc.queryForObject("""
                SELECT count(*) FROM production_finished_in_confirmations confirmation
                JOIN stock_documents document ON document.id = confirmation.stock_document_id
                WHERE document.source_daily_report_id = ?
                """, Integer.class, c.reportId()));
        assertEquals(1, jdbc.queryForObject("""
                SELECT count(*) FROM production_fqc_recovery_authorizations
                WHERE source_report_item_id = ?
                """, Integer.class, c.reportItems().get(1)));
    }

    // ------------------------------------------------------------------ 批量全部合格：逐单落库且预锁一次拿全

    @Test
    void preStockedSheetPassAllPostsEveryLineInOneTransaction() {
        Case c = prepare("fip-batch", true, "2", "5");

        var result = quality.passAll(new PassAllBatchRequest(
                c.inspections(), "fip-batch-passall-" + c.reportId()));
        assertFalse(result.replay());
        assertEquals(2, result.items().size());
        assertEquals(0, new BigDecimal("7").compareTo(balance(c.warehouseId(), c.goodsId())),
                "两行合格量都按登记位置进库存");
        assertEquals(2, jdbc.queryForObject("""
                SELECT count(*) FROM production_finished_in_confirmations confirmation
                JOIN stock_documents document ON document.id = confirmation.stock_document_id
                WHERE document.source_daily_report_id = ? AND confirmation.origin = 'PRE_STOCKED_AUTO'
                """, Integer.class, c.reportId()));
        assertEquals(0, finishedInDocs(c.reportId(), 0), "批量合格后同样没有待点收任务");
    }

    // ------------------------------------------------------------------ 原流程与守卫

    @Test
    void plainRegistrationStillWaitsForWarehouseAndAutoLaneRejectsForeignDocuments() {
        Case c = prepare("fip-plain", false, "6");

        // ① 不点「先入库后质检」时行为一个字节不变：合格只生成待点收草稿，库存为 0。
        assertEquals(Boolean.FALSE, jdbc.queryForObject(
                "SELECT stock_in_before_inspection FROM production_finished_arrival_registrations WHERE source_report_id = ?",
                Boolean.class, c.reportId()));
        quality.decide(c.inspections().getFirst(), new DecisionRequest(
                "PASS", null, null, null, "原流程合格", "fip-plain-pass-" + c.inspections().getFirst()));
        assertEquals(0, balance(c.warehouseId(), c.goodsId()).signum(), "原流程放行不写库存");
        assertEquals(1, finishedInDocs(c.reportId(), 0), "仓库照常收到待点收任务");
        assertEquals(0, jdbc.queryForObject("""
                SELECT count(*) FROM production_finished_in_confirmations confirmation
                JOIN stock_documents document ON document.id = confirmation.stock_document_id
                WHERE document.source_daily_report_id = ?
                """, Integer.class, c.reportId()));

        // ② 自动点收通道「证据即授权」：普通放行草稿借不到这条路(否则任何品质账号都能
        //    绕开仓库点收任意成品入库单)。
        UUID draft = jdbc.queryForObject("""
                SELECT id FROM stock_documents
                WHERE source_daily_report_id = ? AND doc_type = 'FINISHED_IN' AND status = 0
                """, UUID.class, c.reportId());
        var denied = assertThrows(ApiException.class, () -> new org.springframework.transaction.support.TransactionTemplate(
                beans.getBean(org.springframework.transaction.PlatformTransactionManager.class))
                .execute(status -> {
                    stockDocs.confirmPreStockedFinishedInbound(draft, "fip-foreign-" + draft);
                    return null;
                }));
        assertEquals(ErrorCode.FORBIDDEN, denied.getCode());
        assertEquals(0, balance(c.warehouseId(), c.goodsId()).signum());
        assertEquals(1, finishedInDocs(c.reportId(), 0), "被拒后单据仍是待点收草稿");
    }

    // ------------------------------------------------------------------ 夹具

    /** 一张已审核报工单 + 逐行送检登记(按 [preStock] 选按钮)，返回链路上要断言的 UUID。 */
    private Case prepare(String tag, boolean preStock, String... quantities) {
        var masters = new FullChainEndToEndTest();
        beans.autowireBean(masters);
        var world = masters.seedWorld(tag + "-" + UUID.randomUUID().toString().substring(0, 6));
        ReflectionTestUtils.invokeMethod(masters, "receiveOpeningInputsForA", world, "20");
        Object report = ReflectionTestUtils.invokeMethod(
                masters, "approvedMultiLineReportOfNewPlan", world, (Object) quantities);
        UUID reportId = ReflectionTestUtils.invokeMethod(report, "id");
        assertNotNull(reportId);
        masters.loginAs(world.superAdminUserId());
        List<UUID> reportItems = jdbc.queryForList("""
                SELECT id FROM production_daily_report_items
                WHERE report_id = ? AND NOT is_deleted ORDER BY line_no
                """, UUID.class, reportId);
        assertEquals(quantities.length, reportItems.size());
        List<String> places = reportItems.stream()
                .map(id -> "CP-" + id.toString().substring(0, 4).toUpperCase(java.util.Locale.ROOT))
                .toList();
        List<ArrivalRegistrationItemRequest> items = new java.util.ArrayList<>();
        for (int index = 0; index < reportItems.size(); index++) {
            items.add(new ArrivalRegistrationItemRequest(reportItems.get(index), places.get(index),
                    preStock ? new BigDecimal(quantities[index]) : null));
        }
        arrivals.register(reportId, new ArrivalRegistrationRequest(
                tag + "-register-" + reportId, world.warehouseId(), items, "先入库后质检链路", preStock));
        List<UUID> inspections = jdbc.queryForList("""
                SELECT inspection.id FROM production_fqc_inspections inspection
                JOIN production_daily_report_items item ON item.id = inspection.source_report_item_id
                WHERE inspection.source_report_id = ? ORDER BY item.line_no
                """, UUID.class, reportId);
        assertEquals(quantities.length, inspections.size());
        UUID goodsId = jdbc.queryForObject(
                "SELECT goods_id FROM production_daily_report_items WHERE id = ?", UUID.class, reportItems.getFirst());
        assertTrue(inspections.stream().allMatch(java.util.Objects::nonNull));
        return new Case(reportId, world.warehouseId(), goodsId, reportItems, inspections, places);
    }

    private record Case(UUID reportId, UUID warehouseId, UUID goodsId,
                        List<UUID> reportItems, List<UUID> inspections, List<String> places) {}

    private BigDecimal balance(UUID warehouseId, UUID goodsId) {
        BigDecimal value = jdbc.queryForObject(
                "SELECT COALESCE(SUM(qty), 0) FROM stock_balances WHERE warehouse_id = ? AND goods_id = ?",
                BigDecimal.class, warehouseId, goodsId);
        return value == null ? BigDecimal.ZERO : value;
    }

    /** [status] 为 null 时数全部成品入库单，否则只数该状态(0 = 待点收)。 */
    private int finishedInDocs(UUID reportId, Integer status) {
        Integer count = status == null
                ? jdbc.queryForObject("""
                        SELECT count(*) FROM stock_documents
                        WHERE source_daily_report_id = ? AND doc_type = 'FINISHED_IN' AND NOT is_deleted
                        """, Integer.class, reportId)
                : jdbc.queryForObject("""
                        SELECT count(*) FROM stock_documents
                        WHERE source_daily_report_id = ? AND doc_type = 'FINISHED_IN'
                          AND NOT is_deleted AND status = ?
                        """, Integer.class, reportId, status);
        return count == null ? 0 : count;
    }
}
