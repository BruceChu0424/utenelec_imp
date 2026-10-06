package com.uten.imp.businesschain;

import com.uten.imp.application.concurrency.FulfillmentSourceConflictException;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.BatchArrivalLine;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalBatchCompleteRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalBatchRegisterItem;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalBatchRegisterRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalBatchRegisterResult;
import com.uten.imp.features.warehouse.inbound.WarehouseArrivalRegistrationService;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
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
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.MaterialView;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.NotifyRequest;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteDecision;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.RouteRequest;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

/**
 * 2026-10-06 用户实测缺陷复现: 「登记实际到货」勾选多行批量登记(含从仓库任务中心多选进入), 本批涉及多张订货单时
 * 整批 409「相关订单、库存或任务信息已变化」, 一行一行登记却都成功。
 *
 * <p>用户现场: 4 行来自 3 张采购订货单(第一张两行)、2 个入库仓, 4 张订货单明细出自同一份物料分析的采购申请;
 * 服务端按「订货单 x 入库仓库」分为 4 组, 一个事务逐组建收货单。服务端日志是结构性预锁缺口
 * (不重跑): 回调来源超出本次完整预锁集合, 缺少排在后面那张采购订货单。</p>
 *
 * <p>这里用真实服务栈(切 AuthUser)造同样形状的数据, 两条路线(先质检后入库 / 先入库后质检)各批量登记一次;
 * 另补两种同根形状: 订货单不挂物料分析(手工采购申请)、两张委外订货单回厂。期望: 整批成功, 每组一张收货单,
 * 同键重放返回原结果。</p>
 *
 * <p>修复(批量先合并预锁, ADR-107 第六节)后的回归: 两组落在不同主仓; 批量登记与逐行登记逐项等价(含一组超量隔离、
 * 品质合格后按库位转正的库存、应付与预计到货任务); 两张订货单的草稿批量继续送检; 两个批量并发争同一订货明细。
 * 默认配置(嵌套足迹诊断开)与生产配置({@code UTEN_CONCURRENCY_VERIFYNESTEDFOOTPRINT=false})都要通过。</p>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000"})
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = ArrivalRegistrationBatchPrelockCoverageEndToEndTest.Cleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class ArrivalRegistrationBatchPrelockCoverageEndToEndTest {
    private static final PostgreSQLContainer<?> DATABASE = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final String SECRET = UUID.randomUUID() + "-" + UUID.randomUUID();
    private static final String INSPECTED = "SUBMITTED_FOR_INSPECTION";
    private static final String PRE_STOCKED = "STOCKED_PENDING_INSPECTION";
    private static final BigDecimal ORDERED = new BigDecimal("2.5");
    private static final BigDecimal ARRIVED = new BigDecimal("1.25");

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry properties) {
        DATABASE.start();
        properties.add("spring.datasource.url", DATABASE::getJdbcUrl);
        properties.add("spring.datasource.username", DATABASE::getUsername);
        properties.add("spring.datasource.password", DATABASE::getPassword);
        properties.add("uten.jwt.secret", () -> SECRET);
        properties.add("uten.crypto.pgp-master-key", () -> SECRET);
        properties.add("uten.crypto.hmac-key", () -> SECRET);
        properties.add("uten.bootstrap.admin-login", () -> "arrival-prelock-bootstrap");
        properties.add("uten.bootstrap.admin-password", () -> SECRET + "Aa1!");
    }

    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder() - 1; }
        @Override public void afterTestClass(TestContext ignored) { DATABASE.stop(); }
    }

    @Autowired JdbcTemplate jdbc;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired WarehouseArrivalRegistrationService arrivals;
    @Autowired MaterialAnalysisService analysis;
    @Autowired MaterialAnalysisCommandService analysisCommands;
    @Autowired PurchaseRequestService purchaseRequests;
    @Autowired PurchaseOrderService purchaseOrders;
    @Autowired ProcurementFinanceApprovalService financeApproval;
    @Autowired com.uten.imp.features.purchase.receipt.PurchaseReceiptService purchaseReceipts;
    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementInspectionService inspections;
    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementArrivalControlService arrivalControl;

    @AfterEach
    void cleanup() { SecurityContextHolder.clearContext(); }

    // ------------------------------------------------------------------ 用户现场形状: 同一份物料分析的 3 张采购订货单

    @Test
    void analysisPurchaseOrdersAcrossTwoWarehousesRegisterInOneBatchInspectFirst() {
        Case c = purchaseCase("apf", true);
        assertBatchRegistered(c, false);
    }

    @Test
    void analysisPurchaseOrdersAcrossTwoWarehousesRegisterInOneBatchStockInFirst() {
        Case c = purchaseCase("aps", true);
        assertBatchRegistered(c, true);
    }

    // ------------------------------------------------------------------ 同根形状: 订货单不挂物料分析(手工采购申请)

    @Test
    void manualRequestPurchaseOrdersAcrossTwoWarehousesRegisterInOneBatch() {
        Case c = purchaseCase("mpf", false);
        assertBatchRegistered(c, false);
    }

    // ------------------------------------------------------------------ 同根形状: 两张委外订货单一起回厂

    @Test
    void twoSubcontractOrdersReturnInOneBatch() {
        String tag = "arp-sc-" + UUID.randomUUID().toString().substring(0, 8);
        var masters = masters();
        var w = masters.seedWorld(tag);
        masters.loginAs(w.superAdminUserId());
        UUID hardware = leaf(w, "五金车间", tag), packing = leaf(w, "包材仓库", tag);
        // 主仓已有子仓, 直属物料入库、委外下单都落到子仓(父仓只用于汇总)。
        var sourceWorld = WarehouseIqcScaleFixture.withWarehouse(w, hardware);
        UUID material = masters.ensureSubcontractDirectMaterial(w, w.goodsE());
        masters.receiveSubcontractMaterial(w, material, "20", hardware);
        List<UUID> orders = new ArrayList<>();
        for (int index = 0; index < 2; index++) {
            var submitted = masters.submitLeafSubcontractForFinance(sourceWorld, BigDecimal.TEN);
            masters.loginAs(submitted.reviewerUserId());
            masters.approvePendingFinance("SUBCONTRACT", submitted.orderId());
            masters.loginAs(w.superAdminUserId());
            UUID item = jdbc.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=? AND NOT is_deleted",
                    UUID.class, submitted.orderId());
            masters.drawAndIssueSubcontract(item, BigDecimal.TEN, "arp-sc-draw-" + item);
            orders.add(submitted.orderId());
        }
        masters.loginAs(w.superAdminUserId());
        List<Line> lines = List.of(
                subcontractLine(orders.get(0), hardware, w.goodsE()),
                subcontractLine(orders.get(1), packing, w.goodsE()));
        assertBatchRegistered(new Case(tag, w, "SUBCONTRACT", lines), false);
    }

    // ------------------------------------------------------------------ 两组落在不同主仓

    /** 两组落在不同主仓: 两个主仓的协调锁都要在写第一组之前拿到(诊断开关下第二组的主仓不在预锁里会被拦下)。 */
    @Test
    void purchaseOrdersAcrossTwoMainWarehousesRegisterInOneBatch() {
        Case c = purchaseCase("xmw", true, true);
        assertBatchRegistered(c, true);
    }

    // ------------------------------------------------------------------ 批量登记与逐行登记结果等价

    /**
     * 同样两份数据(用户现场形状, 其中一行实到超量), 一份整批登记, 一份一行一行登记, 再把待检全部判合格:
     * 收货单张数与分组、超量隔离与到货异常、订货明细累计到货、应付、按库位转正的库存、预计到货任务状态逐项相同。
     */
    @Test
    void batchRegistrationEqualsLineByLineRegistration() {
        Case batch = withExcess(purchaseCase("eqb", true), 3);
        Case single = withExcess(purchaseCase("eqs", true), 3);

        masters().loginAs(batch.world().superAdminUserId());
        WarehouseArrivalBatchRegisterResult whole = register(request(batch, "arrival-eq-batch-" + batch.tag(), true));
        List<String> batchOutcomes = batch.lines().stream().map(line -> whole.items().stream()
                .filter(item -> item.orderId().equals(line.orderId()) && item.warehouseId().equals(line.warehouseId()))
                .findFirst().orElseThrow().outcome()).toList();

        masters().loginAs(single.world().superAdminUserId());
        List<String> singleOutcomes = new ArrayList<>();
        for (int index = 0; index < single.lines().size(); index++) {
            Case one = new Case(single.tag(), single.world(), single.orderType(), List.of(single.lines().get(index)));
            singleOutcomes.add(register(request(one, "arrival-eq-line-" + index + "-" + single.tag(), true))
                    .items().getFirst().outcome());
        }
        assertEquals(List.of(PRE_STOCKED, PRE_STOCKED, PRE_STOCKED, "EXCESS_QUARANTINED"), batchOutcomes);
        assertEquals(batchOutcomes, singleOutcomes);

        passEveryInspection(batch);
        passEveryInspection(single);
        assertEquals(facts(single), facts(batch));
    }

    // ------------------------------------------------------------------ 断点恢复: 两张订货单的草稿批量继续送检

    /** 「批量继续送检」同样一次预锁全部收货单(含不同订货单), 逐张送检审核只核对覆盖。 */
    @Test
    void interruptedDraftsOfTwoOrdersCompleteInOneBatch() {
        Case c = purchaseCase("cpl", false);
        masters().loginAs(c.world().superAdminUserId());
        List<Line> lines = List.of(c.lines().get(0), c.lines().get(2));
        List<UUID> drafts = new ArrayList<>();
        for (Line line : lines) drafts.add(purchaseDraft(c, line));
        assertEquals(2, lines.stream().map(Line::orderId).distinct().count(), "复现前提: 两张草稿来自两张订货单");

        var completed = arrivals.completeBatch(new WarehouseArrivalBatchCompleteRequest(
                "arrival-complete-" + c.tag(), drafts));
        assertEquals(2, completed.processedCount());
        for (var item : completed.items()) {
            assertEquals(INSPECTED, item.outcome(), "收货单 " + item.receiptBillNo());
            assertEquals(1, jdbc.queryForObject("SELECT status FROM purchase_receipts WHERE id=?", Integer.class,
                    item.receiptId()));
        }
        for (Line line : lines) {
            assertEquals(0, line.qty().compareTo(jdbc.queryForObject(
                    "SELECT received_qty FROM purchase_order_items WHERE id=?", BigDecimal.class, line.orderItemId())));
        }
    }

    // ------------------------------------------------------------------ 并发: 两个批量争同一张订货单

    /**
     * 两个人同时批量登记, 两批都含同一张订货单的同一行(各到一部分)和各自另一张订货单: 合并预锁按稳定顺序
     * 一次拿齐, 后到的一批排队等锁、发现来源变了就由服务端整批自动重跑, 两批都成功, 不死锁、不多收。
     */
    @Test
    void twoConcurrentBatchesSharingAnOrderBothRegister() throws Exception {
        Case c = purchaseCase("ccr", true);
        Line shared = c.lines().get(0);
        Line part = new Line(shared.orderType(), shared.orderId(), shared.orderItemId(), shared.orderBillNo(),
                shared.goodsId(), shared.warehouseId(), BigDecimal.ONE, shared.place());
        Case first = new Case(c.tag(), c.world(), c.orderType(), List.of(part, c.lines().get(2)));
        Case second = new Case(c.tag(), c.world(), c.orderType(), List.of(part, c.lines().get(3)));
        var start = new java.util.concurrent.CountDownLatch(1);
        var workers = java.util.concurrent.Executors.newFixedThreadPool(2);
        try {
            var a = workers.submit(() -> concurrentRegister(first, "arrival-cc-a-" + c.tag(), start));
            var b = workers.submit(() -> concurrentRegister(second, "arrival-cc-b-" + c.tag(), start));
            start.countDown();
            assertEquals(2, a.get(90, java.util.concurrent.TimeUnit.SECONDS).groupCount());
            assertEquals(2, b.get(90, java.util.concurrent.TimeUnit.SECONDS).groupCount());
        } finally {
            workers.shutdownNow();
        }
        assertEquals(0, new BigDecimal("2").compareTo(jdbc.queryForObject(
                "SELECT received_qty FROM purchase_order_items WHERE id=?", BigDecimal.class, shared.orderItemId())),
                "两批各到 1, 不多收不少收");
        assertEquals(4, jdbc.queryForObject("""
                SELECT count(DISTINCT receipt.id) FROM purchase_receipts receipt
                JOIN purchase_receipt_items item ON item.receipt_id = receipt.id AND NOT item.is_deleted
                JOIN purchase_order_items order_item ON order_item.id = item.order_item_id
                WHERE receipt.status = 1 AND order_item.order_id IN (?, ?, ?)
                """, Integer.class, shared.orderId(), c.lines().get(2).orderId(), c.lines().get(3).orderId()));
    }

    private WarehouseArrivalBatchRegisterResult concurrentRegister(Case lines, String key,
                                                                   java.util.concurrent.CountDownLatch start) {
        try {
            masters().loginAs(lines.world().superAdminUserId());
            start.await();
            return register(request(lines, key, true));
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException(interrupted);
        } finally {
            SecurityContextHolder.clearContext();
        }
    }

    // ------------------------------------------------------------------ 断言: 整批成功、每组一张收货单、同键重放

    private void assertBatchRegistered(Case c, boolean stockInFirst) {
        String key = "arrival-prelock-" + c.tag() + (stockInFirst ? "-s" : "-f");
        Set<List<UUID>> expectedGroups = c.lines().stream()
                .map(line -> List.of(line.orderId(), line.warehouseId())).collect(Collectors.toSet());
        Set<UUID> orderIds = c.lines().stream().map(Line::orderId).collect(Collectors.toSet());
        assertTrue(orderIds.size() >= 2, "复现前提: 本批至少两张订货单");

        WarehouseArrivalBatchRegisterResult result = register(request(c, key, stockInFirst));

        String outcome = stockInFirst ? PRE_STOCKED : INSPECTED;
        assertEquals(expectedGroups.size(), result.groupCount());
        assertFalse(result.replay());
        assertEquals(expectedGroups, result.items().stream()
                .map(item -> List.of(item.orderId(), item.warehouseId())).collect(Collectors.toSet()));
        for (WarehouseArrivalBatchRegisterItem item : result.items()) {
            assertEquals(outcome, item.outcome(), "订货单 " + item.orderId() + " 仓 " + item.warehouseId());
            assertNotNull(item.receiptId());
        }
        // 每组一张已审核(送检)收货单, 入库仓即登记行的仓; 订货明细累计到货等于本次登记量。
        String prefix = c.orderType().equals("PURCHASE") ? "purchase" : "subcontract";
        Set<List<UUID>> receiptGroups = new java.util.HashSet<>(jdbc.query("""
                SELECT DISTINCT order_item.order_id, receipt.warehouse_id
                FROM %1$s_receipts receipt
                JOIN %1$s_receipt_items item ON item.receipt_id = receipt.id AND NOT item.is_deleted
                JOIN %1$s_order_items order_item ON order_item.id = item.order_item_id
                WHERE receipt.status = 1 AND order_item.order_id IN (%2$s)
                """.formatted(prefix, placeholders(orderIds.size())),
                (rs, row) -> List.of(rs.getObject(1, UUID.class), rs.getObject(2, UUID.class)), orderIds.toArray()));
        assertEquals(expectedGroups, receiptGroups);
        for (Line line : c.lines()) {
            assertEquals(0, line.qty().compareTo(jdbc.queryForObject(
                    "SELECT received_qty FROM " + prefix + "_order_items WHERE id=?", BigDecimal.class, line.orderItemId())),
                    "订货明细 " + line.orderItemId() + " 累计到货");
        }
        int inspections = jdbc.queryForObject("""
                SELECT count(*) FROM procurement_inspection_items inspection
                WHERE inspection.receipt_type = ? AND inspection.receipt_id IN (%s)
                """.formatted(placeholders(result.items().size())), Integer.class,
                concat(c.orderType(), result.items().stream().map(WarehouseArrivalBatchRegisterItem::receiptId).toList()));
        assertEquals(c.lines().size(), inspections, "每行一条待检明细");
        if (stockInFirst) {
            // 先入库后质检: 每行按登记的仓与库位上架, 库存要等品质合格才转正。
            for (Line line : c.lines()) {
                Map<String, Object> shelved = jdbc.queryForMap("""
                        SELECT inspection.pre_stocked_warehouse_id, inspection.pre_stocked_place
                        FROM procurement_inspection_items inspection
                        JOIN %s_receipt_items item ON item.id = inspection.receipt_item_id
                        WHERE item.order_item_id = ?
                        """.formatted(prefix), line.orderItemId());
                assertEquals(line.warehouseId(), shelved.get("pre_stocked_warehouse_id"));
                assertEquals(line.place(), shelved.get("pre_stocked_place"));
            }
        }

        // 丢响应后原样重试: 整批重放, 收货单不多建。
        WarehouseArrivalBatchRegisterResult replayed = register(request(c, key, stockInFirst));
        assertTrue(replayed.replay());
        assertEquals(result.items().stream().map(WarehouseArrivalBatchRegisterItem::receiptId).collect(Collectors.toSet()),
                replayed.items().stream().map(WarehouseArrivalBatchRegisterItem::receiptId).collect(Collectors.toSet()));
    }

    /** 把履约预锁拒绝(409)的服务端内部原因带进失败信息, 红灯时直接看到缺的是哪张单。 */
    private WarehouseArrivalBatchRegisterResult register(WarehouseArrivalBatchRegisterRequest request) {
        try {
            return arrivals.registerBatch(request);
        } catch (FulfillmentSourceConflictException conflict) {
            return fail("批量登记实际到货被履约预锁拒绝(409, retryable=" + conflict.retryable() + "): "
                    + conflict.internalReason(), conflict);
        }
    }

    // ------------------------------------------------------------------ 造数据

    /**
     * 3 张采购订货单(第一张两行)、2 个入库仓: A1->五金车间、A2->包材仓库、B->五金车间、C->包材仓库。
     * fromAnalysis = 4 种料出自同一份物料分析的采购申请(用户现场); 否则出自一张手工采购申请。
     */
    private Case purchaseCase(String label, boolean fromAnalysis) {
        return purchaseCase(label, fromAnalysis, false);
    }

    /** packingInAnotherMain = 包材仓库挂在另一个主仓下(两组落在不同主仓)。 */
    private Case purchaseCase(String label, boolean fromAnalysis, boolean packingInAnotherMain) {
        String tag = "arp-" + label + "-" + UUID.randomUUID().toString().substring(0, 8);
        var masters = masters();
        var w = masters.seedWorld(tag);
        masters.loginAs(w.superAdminUserId());
        UUID hardware = leaf(w, "五金车间", tag);
        UUID packing = packingInAnotherMain ? leafUnder(mainWarehouse("另一主仓", tag), "包材仓库", tag)
                : leaf(w, "包材仓库", tag);
        UUID supplierB = supplier("B", tag), supplierC = supplier("C", tag);
        List<UUID> goods = new ArrayList<>(List.of(w.goodsD()));
        for (int index = 1; index < 4; index++) {
            UUID id = UUID.randomUUID();
            masters.insertGoods(id, "ARP-" + tag + "-" + index, "批量到货料" + index + "-" + tag, "采购",
                    w.unitId(), w.unitLegacy());
            goods.add(id);
        }
        List<UUID> suppliers = List.of(w.supplierId(), w.supplierId(), supplierB, supplierC);
        for (int index = 0; index < goods.size(); index++) {
            jdbc.update("UPDATE goods SET default_supplier_id=? WHERE id=?", suppliers.get(index), goods.get(index));
        }
        Map<UUID, UUID> requestItems = fromAnalysis ? analysisRequestItems(w, goods, tag)
                : manualRequestItems(w, hardware, goods);

        // 一次拆单按明细供应商生成 3 张订货单(与现场 CD...001/002/003 同一秒生成一致), 再逐张送审、财务批准。
        var order = new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        order.setBillDate(BusinessTime.today());
        order.setSupplierId(w.supplierId());
        order.setCurrencyId(w.currencyId());
        order.setExchangeRate(BigDecimal.ONE);
        order.setTaxRate(BigDecimal.ZERO);
        UUID settlement = ReflectionTestUtils.invokeMethod(masters, "activeSettlementMethodId");
        order.setSettlementMethodId(settlement);
        List<com.uten.imp.features.purchase.order.dto.OrderItemLine> orderLines = new ArrayList<>();
        for (int index = 0; index < goods.size(); index++) {
            var line = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
            line.setGoodsId(goods.get(index));
            line.setSupplierId(suppliers.get(index));
            line.setRequestItemId(requestItems.get(goods.get(index)));
            line.setUnitId(w.unitId());
            line.setUnitRate(BigDecimal.ONE);
            line.setQty(ORDERED);
            line.setPrice(new BigDecimal("50"));
            orderLines.add(line);
        }
        order.setItems(orderLines);
        var created = purchaseOrders.createBatch(order);
        assertEquals(3, created.size(), "按明细供应商拆成 3 张订货单");
        UUID reviewer = ReflectionTestUtils.invokeMethod(masters, "createApprover", w);
        for (var detail : created) {
            masters.loginAs(w.superAdminUserId());
            financeApproval.submit("PURCHASE", detail.getId());
            masters.loginAs(reviewer);
            masters.approvePendingFinance("PURCHASE", detail.getId());
        }
        masters.loginAs(w.superAdminUserId());

        List<UUID> warehouses = List.of(hardware, packing, hardware, packing);
        List<Line> lines = new ArrayList<>();
        for (int index = 0; index < goods.size(); index++) {
            Map<String, Object> source = jdbc.queryForMap("""
                    SELECT item.id, item.order_id, header.bill_no
                    FROM purchase_order_items item JOIN purchase_orders header ON header.id = item.order_id
                    WHERE item.request_item_id = ? AND NOT item.is_deleted AND NOT header.is_deleted
                    """, requestItems.get(goods.get(index)));
            lines.add(new Line("PURCHASE", (UUID) source.get("order_id"), (UUID) source.get("id"),
                    (String) source.get("bill_no"), goods.get(index), warehouses.get(index), ARRIVED,
                    "P-" + (index + 1)));
        }
        assertEquals(3, lines.stream().map(Line::orderId).distinct().count());
        assertEquals(lines.get(0).orderId(), lines.get(1).orderId(), "第一张订货单两行分到两个仓");
        return new Case(tag, w, "PURCHASE", lines);
    }

    /** 成品挂 4 种采购料, 物料分析定 BUY 路线并通知采购, 返回 货品 -> 采购申请明细。 */
    private Map<UUID, UUID> analysisRequestItems(FullChainEndToEndTest.World w, List<UUID> goods, String tag) {
        var masters = masters();
        UUID finished = UUID.randomUUID();
        masters.insertGoods(finished, "ARP-F-" + tag, "批量到货成品-" + tag, "自制", w.unitId(), w.unitLegacy());
        for (UUID material : goods) masters.insertBom(finished, material, "1");
        var view = analysis.preview(new PreviewRequest(null, null, null, w.warehouseId(), "arp-preview-" + tag,
                List.of(new PreviewItem("OTHER", null, finished, null, w.unitId(), "ARP-" + tag,
                        "批量到货预锁复现", BusinessTime.today(), ORDERED))));
        List<MaterialView> buyRows = view.flatMaterials().stream()
                .filter(row -> goods.contains(row.goodsId()) && row.actionable()).toList();
        assertEquals(goods.size(), buyRows.size());
        var routed = analysis.saveRoutes(view.analysisId(), new RouteRequest(view.version(), view.fingerprint(),
                "arp-route-" + tag, buyRows.stream()
                        .map(row -> new RouteDecision(row.materialLineId(), row.actionGroupKey(), "BUY", null)).toList()));
        analysisCommands.notifySupply(view.analysisId(), new NotifyRequest(routed.version(), routed.fingerprint(),
                "arp-notify-" + tag, "BUY", buyRows.stream().map(MaterialView::materialLineId).toList(), List.of(), null));
        Map<UUID, UUID> result = new LinkedHashMap<>();
        jdbc.query("""
                SELECT item.goods_id, item.id FROM purchase_request_items item
                WHERE NOT item.is_deleted AND EXISTS (SELECT 1 FROM preplan_supply_actions action
                    WHERE action.analysis_id = ? AND action.route = 'BUY' AND action.status = 'CREATED'
                      AND action.external_document_id = item.request_id)
                """, rs -> {
            result.put(rs.getObject(1, UUID.class), rs.getObject(2, UUID.class));
        }, view.analysisId());
        assertEquals(Set.copyOf(goods), result.keySet());
        return result;
    }

    /** 一张手工采购申请(不挂物料分析)列 4 种料, 审核后返回 货品 -> 采购申请明细。主仓已有子仓, 申请落到子仓。 */
    private Map<UUID, UUID> manualRequestItems(FullChainEndToEndTest.World w, UUID warehouse, List<UUID> goods) {
        var request = new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setWarehouseId(warehouse);
        request.setDepartmentId(w.departmentId());
        request.setApplicantId(w.employeeId());
        request.setItems(goods.stream().map(id -> {
            var line = new com.uten.imp.features.purchase.request.dto.RequestItemLine();
            line.setGoodsId(id);
            line.setUnitId(w.unitId());
            line.setUnitRate(BigDecimal.ONE);
            line.setQty(ORDERED);
            return line;
        }).toList());
        UUID requestId = purchaseRequests.create(request).getId();
        purchaseRequests.approve(requestId);
        Map<UUID, UUID> result = new LinkedHashMap<>();
        jdbc.query("SELECT goods_id, id FROM purchase_request_items WHERE request_id=? AND NOT is_deleted",
                rs -> {
                    result.put(rs.getObject(1, UUID.class), rs.getObject(2, UUID.class));
                }, requestId);
        assertEquals(Set.copyOf(goods), result.keySet());
        return result;
    }

    private Line subcontractLine(UUID orderId, UUID warehouse, UUID goods) {
        Map<String, Object> source = jdbc.queryForMap("""
                SELECT item.id, header.bill_no, item.qty FROM subcontract_order_items item
                JOIN subcontract_orders header ON header.id = item.order_id
                WHERE item.order_id = ? AND NOT item.is_deleted
                """, orderId);
        // 整单回厂, 不触发短交确认弹窗。
        return new Line("SUBCONTRACT", orderId, (UUID) source.get("id"), (String) source.get("bill_no"), goods,
                warehouse, (BigDecimal) source.get("qty"), "S-" + orderId.toString().substring(0, 4));
    }

    /** 与「登记实际到货」页提交的请求体一致: 采购行不带换算率、带采购员; 委外行带换算率。 */
    private static WarehouseArrivalBatchRegisterRequest request(Case c, String key, boolean stockInFirst) {
        boolean purchase = c.orderType().equals("PURCHASE");
        return new WarehouseArrivalBatchRegisterRequest(key, BusinessTime.today(), c.world().employeeId(),
                "批量登记实际到货", stockInFirst ? Boolean.TRUE : null, null,
                c.lines().stream().map(line -> new BatchArrivalLine(c.orderType(), line.warehouseId(),
                        purchase ? c.world().employeeId() : null, line.goodsId(), line.qty(), line.orderItemId(),
                        null, c.world().unitId(), purchase ? null : BigDecimal.ONE, null, line.orderBillNo(), null,
                        stockInFirst ? line.place() : null, null)).toList());
    }

    /** 第 index 行实到超过订货量(允许超收 0%): 这一组整单隔离等财务, 其它组照常。 */
    private static Case withExcess(Case c, int index) {
        List<Line> lines = new ArrayList<>(c.lines());
        Line line = lines.get(index);
        lines.set(index, new Line(line.orderType(), line.orderId(), line.orderItemId(), line.orderBillNo(),
                line.goodsId(), line.warehouseId(), ORDERED.add(BigDecimal.ONE), line.place()));
        return new Case(c.tag(), c.world(), c.orderType(), lines);
    }

    /** 品质部把本数据里全部待检行判合格(先入库后质检: 按上架位置自动转正)。 */
    private void passEveryInspection(Case c) {
        masters().loginAs(c.world().superAdminUserId());
        for (Line line : c.lines()) {
            List<Map<String, Object>> rows = jdbc.queryForList("""
                    SELECT inspection.id, inspection.receipt_id FROM procurement_inspection_items inspection
                    JOIN purchase_receipt_items item ON item.id = inspection.receipt_item_id
                    WHERE inspection.receipt_type = 'PURCHASE' AND item.order_item_id = ?
                      AND inspection.status <> 'RESOLVED'
                    """, line.orderItemId());
            for (Map<String, Object> row : rows) {
                inspections.dispose("PURCHASE", (UUID) row.get("receipt_id"), (UUID) row.get("id"),
                        new InspectionDispositionRequest("PASS", null, "到货检验合格", "arrival-eq-pass-" + row.get("id")));
            }
        }
    }

    /**
     * 与 id 无关的业务结果, 逐行列出(订货单、仓按本数据里首次出现的顺序编号): 收货单状态与入库仓、
     * 同单行数、待财务到货异常、订货明细累计到货、应付、待检状态与上架位置、本行货品在本仓的库存,
     * 以及本订货单的预计到货任务(状态、已登记、已验收、剩余、待检张数、未结异常)。
     */
    private List<String> facts(Case c) {
        Map<UUID, String> orders = new LinkedHashMap<>();
        Map<UUID, String> warehouses = new LinkedHashMap<>();
        for (Line line : c.lines()) {
            orders.putIfAbsent(line.orderId(), "订货单" + (orders.size() + 1));
            warehouses.putIfAbsent(line.warehouseId(), "仓" + (warehouses.size() + 1));
        }
        List<UUID> expectations = jdbc.queryForList("SELECT id FROM inbound_expectations WHERE order_id IN (%s)"
                .formatted(placeholders(orders.size())), UUID.class, orders.keySet().toArray());
        Map<UUID, String> tasks = new java.util.HashMap<>();
        for (var task : arrivalControl.expectationsByIds(expectations)) {
            tasks.put(task.orderId(), String.join("/", task.status(), plain(task.registeredQty()),
                    plain(task.acceptedQty()), plain(task.remainingQty()),
                    String.valueOf(task.pendingInspectionReceipts()), String.valueOf(task.openArrivalExceptions())));
        }
        List<String> facts = new ArrayList<>();
        for (Line line : c.lines()) {
            Map<String, Object> row = jdbc.queryForMap("""
                    SELECT receipt.status, receipt.warehouse_id,
                           (SELECT count(*) FROM purchase_receipt_items sibling
                            WHERE sibling.receipt_id = receipt.id AND NOT sibling.is_deleted) AS receipt_lines,
                           (SELECT count(*) FROM procurement_arrival_exceptions exception
                            WHERE exception.receipt_id = receipt.id AND exception.status = 'PENDING_FINANCE') AS pending_finance,
                           (SELECT coalesce(sum(ledger.amount_original), 0) FROM ar_ap_ledger ledger
                            WHERE ledger.direction = 'AP' AND ledger.source_doc_type = 'PURCHASE_RECEIPT'
                              AND ledger.source_doc_id = receipt.id AND NOT ledger.is_deleted) AS payable,
                           order_item.received_qty, inspection.status AS inspection_status,
                           inspection.pre_stocked_warehouse_id, inspection.pre_stocked_place,
                           (SELECT coalesce(sum(balance.qty), 0) FROM stock_balances balance
                            WHERE balance.warehouse_id = ? AND balance.goods_id = order_item.goods_id) AS on_hand
                    FROM purchase_receipt_items item
                    JOIN purchase_receipts receipt ON receipt.id = item.receipt_id AND NOT receipt.is_deleted
                    JOIN purchase_order_items order_item ON order_item.id = item.order_item_id
                    LEFT JOIN procurement_inspection_items inspection
                      ON inspection.receipt_type = 'PURCHASE' AND inspection.receipt_item_id = item.id
                    WHERE item.order_item_id = ? AND NOT item.is_deleted
                    """, line.warehouseId(), line.orderItemId());
            facts.add(String.join(" | ", orders.get(line.orderId()), warehouses.get(line.warehouseId()),
                    "收货单状态=" + row.get("status"), "入库仓=" + warehouses.get((UUID) row.get("warehouse_id")),
                    "同单行数=" + row.get("receipt_lines"), "待财务异常=" + row.get("pending_finance"),
                    "应付=" + plain((BigDecimal) row.get("payable")),
                    "累计到货=" + plain((BigDecimal) row.get("received_qty")),
                    "待检=" + row.get("inspection_status"),
                    "上架仓=" + warehouses.get((UUID) row.get("pre_stocked_warehouse_id")),
                    "库位=" + row.get("pre_stocked_place"),
                    "本仓库存=" + plain((BigDecimal) row.get("on_hand")),
                    "预计到货任务=" + tasks.get(line.orderId())));
        }
        return facts;
    }

    private static String plain(BigDecimal value) {
        return value == null ? "null" : value.stripTrailingZeros().toPlainString();
    }

    /** 老流程 / 网络中断留下的草稿收货单(只建单、未送检)。 */
    private UUID purchaseDraft(Case c, Line line) {
        Map<String, Object> order = jdbc.queryForMap("""
                SELECT supplier_id, currency_id, exchange_rate, tax_rate, settlement_method_id
                FROM purchase_orders WHERE id = ?
                """, line.orderId());
        var draft = new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();
        draft.setBillDate(BusinessTime.today());
        draft.setSupplierId((UUID) order.get("supplier_id"));
        draft.setWarehouseId(line.warehouseId());
        draft.setCurrencyId((UUID) order.get("currency_id"));
        draft.setExchangeRate((BigDecimal) order.get("exchange_rate"));
        draft.setTaxRate((BigDecimal) order.get("tax_rate"));
        draft.setSettlementMethodId((UUID) order.get("settlement_method_id"));
        draft.setPurchaserId(c.world().employeeId());
        draft.setReceiverId(c.world().employeeId());
        var item = new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();
        item.setLineNo(1);
        item.setGoodsId(line.goodsId());
        item.setUnitId(c.world().unitId());
        item.setQty(line.qty());
        item.setOrderItemId(line.orderItemId());
        draft.setItems(List.of(item));
        return purchaseReceipts.createFromWarehouseArrival(draft).getId();
    }

    private FullChainEndToEndTest masters() {
        var masters = new FullChainEndToEndTest();
        beans.autowireBean(masters);
        return masters;
    }

    private UUID leaf(FullChainEndToEndTest.World w, String name, String tag) {
        return leafUnder(w.warehouseId(), name, tag);
    }

    private UUID leafUnder(UUID parent, String name, String tag) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO warehouses(id,parent_id,code,name,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",
                id, parent, "ARP-" + id.toString().substring(0, 8), name + "-" + tag);
        return id;
    }

    private UUID mainWarehouse(String name, String tag) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO warehouses(id,parent_id,code,name,status,is_accountable) VALUES(?,NULL,?,?,'使用',TRUE)",
                id, "ARM-" + id.toString().substring(0, 8), name + "-" + tag);
        return id;
    }

    private UUID supplier(String label, String tag) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO suppliers(id, code, name, status, code_sequence)
                VALUES (?, ?, ?, '使用', (SELECT coalesce(max(code_sequence), 0) + 1 FROM suppliers))
                """, id, "SUP-" + label + "-" + tag, "供应商" + label + "-" + tag);
        return id;
    }

    private static String placeholders(int count) {
        return String.join(",", Collections.nCopies(count, "?"));
    }

    private static Object[] concat(Object first, List<UUID> rest) {
        List<Object> values = new ArrayList<>();
        values.add(first);
        values.addAll(rest);
        return values.toArray();
    }

    private record Line(String orderType, UUID orderId, UUID orderItemId, String orderBillNo, UUID goodsId,
                        UUID warehouseId, BigDecimal qty, String place) {
    }

    private record Case(String tag, FullChainEndToEndTest.World world, String orderType, List<Line> lines) {
    }
}
