package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.outbox.BusinessOutboxProcessor;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest.ArrivalLine;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockInItem;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockInRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInService;
import com.uten.imp.features.warehouse.inbound.WarehouseArrivalRegistrationService;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultContracts.TaskDetail;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultService;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionDecideRequest;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionPassRequest;
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
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.businesschain.WarehouseIqcScaleFixture.RECEIPT_QTY;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 先入库后质检(V596 / ADR-090)全链路：上架只落位置不落库存；合格按上架位置自动转正
 * (与 V446 仓库确认同一套批次/流水/守卫)；不合格不进库存只留位置；出结论后不能再改上架；
 * 到货登记勾选后同事务上架且需独立权限。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000"})
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = ProcurementIqcPreStockInEndToEndTest.Cleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class ProcurementIqcPreStockInEndToEndTest {
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
        properties.add("uten.bootstrap.admin-login", () -> "iqc-prestock-bootstrap");
        properties.add("uten.bootstrap.admin-password", () -> SECRET + "Aa1!");
    }

    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder() - 1; }
        @Override public void afterTestClass(TestContext ignored) { DATABASE.stop(); }
    }

    @Autowired JdbcTemplate jdbc;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ProcurementInspectionService inspections;
    @Autowired ProcurementIqcPreStockInService preStock;
    @Autowired WarehouseQualityResultService qualityResults;
    @Autowired WarehouseArrivalRegistrationService arrivals;
    @Autowired BusinessOutboxProcessor outbox;

    @AfterEach
    void cleanup() { SecurityContextHolder.clearContext(); }

    // ------------------------------------------------------------------ 采购：上架 → 合格自动转正 / 不合格不进库存

    @Test
    void purchaseLinesShelvedBeforeInspectionAutoStockInOnPassAndStayOutOfStockOnFail() {
        Case c = prepare("PURCHASE");
        UUID first = c.leaves().get(0), second = c.leaves().get(1);
        WarehouseIqcScaleFixture.Receipt line1 = c.rows().get(0), line2 = c.rows().get(1);

        // ① 上架：两行落到不同的记账叶仓；只写位置，库存为 0。
        var shelved = preStock.preStockIn("PURCHASE", c.receipt(), new PreStockInRequest(List.of(
                new PreStockInItem(line1.inspectionId(), first, "A-01"),
                new PreStockInItem(line2.inspectionId(), second, " B-02 "))));
        assertEquals(2, shelved.stockedLineCount());
        assertEquals(0, shelved.replayedLineCount());
        assertEquals(first, jdbc.queryForObject("SELECT pre_stocked_warehouse_id FROM procurement_inspection_items WHERE id=?", UUID.class, line1.inspectionId()));
        assertEquals("B-02", jdbc.queryForObject("SELECT pre_stocked_place FROM procurement_inspection_items WHERE id=?", String.class, line2.inspectionId()));
        assertEquals(c.world().employeeId(), jdbc.queryForObject("SELECT pre_stocked_by_employee_id FROM procurement_inspection_items WHERE id=?", UUID.class, line1.inspectionId()));
        assertEquals(2, events(c.receipt(), "PRE_STOCKED"));
        assertEquals(0, balance(first, line1.goodsId()).signum(), "上架不写库存");
        assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM business_outbox WHERE event_type='PROCUREMENT_IQC_PRE_STOCKED' AND aggregate_id=?", Integer.class, c.receipt()));

        // ② 同内容重放：静默重放，不增事件；改库位：追加一条调整事件。
        var replayed = preStock.preStockIn("PURCHASE", c.receipt(), new PreStockInRequest(List.of(
                new PreStockInItem(line1.inspectionId(), first, "A-01"),
                new PreStockInItem(line2.inspectionId(), second, "B-02"))));
        assertEquals(0, replayed.stockedLineCount());
        assertEquals(2, replayed.replayedLineCount());
        assertEquals(2, events(c.receipt(), "PRE_STOCKED"));
        var moved = preStock.preStockIn("PURCHASE", c.receipt(), new PreStockInRequest(List.of(
                new PreStockInItem(line2.inspectionId(), second, "B-03"))));
        assertEquals(1, moved.stockedLineCount());
        assertEquals("B-03", jdbc.queryForObject("SELECT pre_stocked_place FROM procurement_inspection_items WHERE id=?", String.class, line2.inspectionId()));
        assertEquals(3, events(c.receipt(), "PRE_STOCKED"));
        drainOutbox();

        // ③ 品质合格(整行)：按上架位置自动转正——库存进 first，批次 origin=PRE_STOCKED_AUTO，
        //    不再投递「待仓库确认入库」事件，库位学习为 A-01。
        inspections.dispose("PURCHASE", c.receipt(), line1.inspectionId(),
                new InspectionDispositionRequest("PASS", null, "先入库后检合格", "prestock-pass-" + line1.inspectionId()));
        assertEquals(0, RECEIPT_QTY.compareTo(balance(first, line1.goodsId())), "合格量按上架仓进库存");
        Map<String, Object> batch = jdbc.queryForMap("""
                SELECT batch.origin, batch.confirmed_count, item.warehouse_id, item.place_snapshot, item.base_qty
                FROM procurement_iqc_stock_in_batches batch
                JOIN procurement_iqc_stock_in_batch_items item ON item.batch_id = batch.id
                WHERE item.inspection_item_id = ?
                """, line1.inspectionId());
        assertEquals("PRE_STOCKED_AUTO", batch.get("origin"));
        assertEquals(1, ((Number) batch.get("confirmed_count")).intValue());
        assertEquals(first, batch.get("warehouse_id"));
        assertEquals("A-01", batch.get("place_snapshot"));
        assertEquals(0, RECEIPT_QTY.compareTo((BigDecimal) batch.get("base_qty")));
        assertEquals(0, RECEIPT_QTY.compareTo(jdbc.queryForObject("SELECT warehouse_stocked_base_qty FROM procurement_inspection_items WHERE id=?", BigDecimal.class, line1.inspectionId())));
        assertEquals("RESOLVED", jdbc.queryForObject("SELECT status FROM procurement_inspection_items WHERE id=?", String.class, line1.inspectionId()));
        UUID passEvent = jdbc.queryForObject("SELECT id FROM procurement_inspection_events WHERE inspection_item_id=? AND action='PASS'", UUID.class, line1.inspectionId());
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM business_outbox WHERE event_type='PROCUREMENT_IQC_STOCK_IN_PENDING' AND aggregate_id=?", Integer.class, passEvent),
                "自动转正后不再给仓库发待确认入库任务");
        assertEquals("A-01", jdbc.queryForObject("SELECT place FROM warehouse_goods_place_preferences WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL", String.class, first, line1.goodsId()));

        // ④ 部分合格 + 部分不合格(检验报告)：只有合格量按上架位置进库存；不合格只留事实与位置。
        inspections.decideBatch("PURCHASE", c.receipt(), new BatchInspectionDecideRequest(List.of(
                new BatchInspectionDecideRequest.Item(line2.inspectionId(), RECEIPT_QTY,
                        new BigDecimal("0.75"), new BigDecimal("0.50"), "prestock-mixed-" + line2.inspectionId())),
                "外观划伤"));
        assertEquals(0, new BigDecimal("0.75").compareTo(balance(second, line2.goodsId())));
        assertEquals(0, new BigDecimal("0.50").compareTo(jdbc.queryForObject("SELECT failed_base_qty FROM procurement_inspection_items WHERE id=?", BigDecimal.class, line2.inspectionId())));
        assertEquals("B-03", jdbc.queryForObject("SELECT item.place_snapshot FROM procurement_iqc_stock_in_batch_items item WHERE item.inspection_item_id=?", String.class, line2.inspectionId()));
        assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM business_outbox WHERE event_type='PROCUREMENT_IQC_REJECTION_DETECTED' AND aggregate_id=?", Integer.class, line2.inspectionId()));
        assertEquals(1, events(c.receipt(), "RECEIPT_RESOLVED"), "整单结案事件照常");
        drainOutbox();

        // ⑤ 出了结论就不能再改上架位置(服务 + 数据库触发器双闸)。
        conflict(() -> preStock.preStockIn("PURCHASE", c.receipt(), new PreStockInRequest(List.of(
                new PreStockInItem(line1.inspectionId(), first, "Z-99")))));
        assertThrows(Exception.class, () -> jdbc.update(
                "UPDATE procurement_inspection_items SET pre_stocked_place='Z-99' WHERE id=?", line1.inspectionId()));

        // ⑥ 仓库合并页：明细带位置、历史带来源、退回案件带位置；无可再上架的行。
        TaskDetail detail = qualityResults.detail("PURCHASE", c.receipt());
        assertEquals(2, detail.lines().size());
        assertTrue(detail.lines().stream().allMatch(line -> line.preStocked() != null));
        assertEquals("A-01", detail.lines().stream().filter(line -> line.inspectionItemId().equals(line1.inspectionId())).findFirst().orElseThrow().preStocked().place());
        assertTrue(detail.history().stream().allMatch(item -> "PRE_STOCKED_AUTO".equals(item.origin())));
        assertEquals(0, detail.preStockedLineCount(), "全部出结论后不再有等结论的上架行");
        assertFalse(detail.allowedActions().contains(TaskDetail.ACTION_PRE_STOCK_IN));
        assertTrue(detail.rejections().stream().allMatch(item -> item.preStocked() != null && "B-03".equals(item.preStocked().place())));
    }

    // ------------------------------------------------------------------ 委外：整单一键合格 → 每行自动转正(含原材料批次拆分)

    @Test
    void subcontractReceiptShelvedThenFullPassBatchAutoStocksEveryLine() {
        Case c = prepare("SUBCONTRACT");
        UUID leaf = c.leaves().get(0);
        preStock.preStockIn("SUBCONTRACT", c.receipt(), new PreStockInRequest(c.rows().stream()
                .map(row -> new PreStockInItem(row.inspectionId(), leaf, "S-" + row.goodsId().toString().substring(0, 4))).toList()));
        var request = new BatchInspectionPassRequest(c.rows().stream().map(row ->
                new BatchInspectionPassRequest.Item(row.inspectionId(), RECEIPT_QTY, "prestock-full-" + row.inspectionId())).toList(), null);
        inspections.passBatch("SUBCONTRACT", c.receipt(), request);
        for (var row : c.rows()) {
            assertEquals(0, RECEIPT_QTY.compareTo(balance(leaf, row.goodsId())), "委外回厂合格量按上架仓进库存");
            assertEquals(0, RECEIPT_QTY.compareTo(jdbc.queryForObject("SELECT warehouse_stocked_base_qty FROM procurement_inspection_items WHERE id=?", BigDecimal.class, row.inspectionId())));
        }
        // 2026-09-21：一次结论里所有已上架合格行合成一个自动批次(此前每行一个批次)，行数仍逐行守恒。
        assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=? AND origin='PRE_STOCKED_AUTO'", Integer.class, c.receipt()));
        assertEquals(c.rows().size(), jdbc.queryForObject("SELECT confirmed_count FROM procurement_iqc_stock_in_batches WHERE receipt_id=? AND origin='PRE_STOCKED_AUTO'", Integer.class, c.receipt()));
        assertEquals(c.rows().size(), jdbc.queryForObject("SELECT count(*) FROM procurement_iqc_stock_in_batch_items item JOIN procurement_iqc_stock_in_batches batch ON batch.id=item.batch_id WHERE batch.receipt_id=?", Integer.class, c.receipt()));
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM business_outbox WHERE event_type='PROCUREMENT_IQC_STOCK_IN_PENDING' AND payload::text LIKE '%' || ? || '%'", Integer.class, c.receipt().toString()));
        // 同一批次重放：不再产生新批次、库存不翻倍。
        inspections.passBatch("SUBCONTRACT", c.receipt(), request);
        assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=?", Integer.class, c.receipt()));
        for (var row : c.rows()) assertEquals(0, RECEIPT_QTY.compareTo(balance(leaf, row.goodsId())));
        drainOutbox();
    }

    // ------------------------------------------------------------------ 守卫：非叶仓 / 空库位 / 不存在的明细

    @Test
    void shelvingRejectsNonLeafWarehousesBlankPlacesAndForeignLines() {
        Case c = prepare("PURCHASE");
        var line = c.rows().get(0);
        assertThrows(ApiException.class, () -> preStock.preStockIn("PURCHASE", c.receipt(), new PreStockInRequest(List.of(
                new PreStockInItem(line.inspectionId(), c.world().warehouseId(), "P-01")))), "父仓不是记账叶仓");
        assertEquals(ErrorCode.VALIDATION_FAILED, assertThrows(ApiException.class, () -> preStock.preStockIn("PURCHASE", c.receipt(),
                new PreStockInRequest(List.of(new PreStockInItem(line.inspectionId(), c.leaves().get(0), "   "))))).getCode());
        assertEquals(ErrorCode.NOT_FOUND, assertThrows(ApiException.class, () -> preStock.preStockIn("PURCHASE", c.receipt(),
                new PreStockInRequest(List.of(new PreStockInItem(UUID.randomUUID(), c.leaves().get(0), "P-01"))))).getCode());
        assertNull(jdbc.queryForObject("SELECT pre_stocked_at FROM procurement_inspection_items WHERE id=?", java.sql.Timestamp.class, line.inspectionId()));
        assertEquals(0, events(c.receipt(), "PRE_STOCKED"));
    }

    // ------------------------------------------------------------------ 到货登记勾选「先入库后质检」：同事务上架，需独立权限

    @Test
    void registrationWithStockInFirstShelvesInTheSameTransactionAndRequiresItsOwnAuthority() {
        String tag = "psr-" + UUID.randomUUID().toString().substring(0, 8);
        var masters = new FullChainEndToEndTest();
        beans.autowireBean(masters);
        var w = masters.seedWorld(tag);
        masters.loginAs(w.superAdminUserId());
        UUID leaf = UUID.randomUUID();
        jdbc.update("INSERT INTO warehouses(id,parent_id,code,name,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",
                leaf, w.warehouseId(), "PS-L-" + tag, "先入库叶仓");
        UUID finished = UUID.randomUUID();
        masters.insertGoods(finished, "PSF-" + tag, "先入库成品", "自制", w.unitId(), w.unitLegacy());
        masters.insertBom(finished, w.goodsD(), "1");
        jdbc.update("UPDATE goods SET default_supplier_id=? WHERE id=?", w.supplierId(), w.goodsD());
        var view = beans.getBean(MaterialAnalysisService.class).preview(new PreviewRequest(null, null, null, w.warehouseId(),
                "prestock-preview-" + tag, List.of(new PreviewItem("OTHER", null, finished, null, w.unitId(),
                        "PRESTOCK-" + tag, "先入库后检登记", BusinessTime.today(), new BigDecimal("2.5")))));
        UUID purchaseItem = ReflectionTestUtils.invokeMethod(masters, "approvePurchaseForAnalysis",
                WarehouseIqcScaleFixture.withWarehouse(w, leaf), view, w.goodsD());
        assertNotNull(purchaseItem);
        masters.loginAs(w.superAdminUserId());

        // 无独立权限：勾选先入库直接 403，什么都不写。
        UUID plainWarehouseUser = masters.createUserWithPerms(w, "prestock-noauth-" + tag,
                "warehouse_inbound:view", "warehouse_inbound:stock_in");
        masters.loginAs(plainWarehouseUser);
        var denied = assertThrows(ApiException.class, () -> arrivals.register(request("prestock-denied-" + tag, w, leaf, purchaseItem, true)));
        assertEquals(ErrorCode.FORBIDDEN, denied.getCode());
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM purchase_receipts WHERE supplier_id=?", Integer.class, w.supplierId()));

        // 有权限：登记 + 送检 + 上架同事务；结果码 STOCKED_PENDING_INSPECTION；同键重放安全。
        masters.loginAs(w.superAdminUserId());
        var registered = arrivals.register(request("prestock-ok-" + tag, w, leaf, purchaseItem, true));
        assertEquals("STOCKED_PENDING_INSPECTION", registered.outcome());
        UUID receipt = registered.receiptId();
        Map<String, Object> line = jdbc.queryForMap("SELECT id, pre_stocked_warehouse_id, pre_stocked_place, status FROM procurement_inspection_items WHERE receipt_type='PURCHASE' AND receipt_id=?", receipt);
        assertEquals(leaf, line.get("pre_stocked_warehouse_id"));
        assertEquals("R-07", line.get("pre_stocked_place"));
        assertEquals("PENDING", line.get("status"));
        assertEquals("STOCKED_PENDING_INSPECTION", jdbc.queryForObject("SELECT outcome FROM warehouse_arrival_registration_commands WHERE idempotency_key=?", String.class, "prestock-ok-" + tag));
        var replayed = arrivals.register(request("prestock-ok-" + tag, w, leaf, purchaseItem, true));
        assertEquals("STOCKED_PENDING_INSPECTION", replayed.outcome());
        assertEquals(receipt, replayed.receiptId());
        assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM procurement_inspection_items WHERE receipt_id=?", Integer.class, receipt));
        // 同键不同内容(取消勾选)：幂等键冲突，不能偷偷把已上架的登记改成原流程。
        conflict(() -> arrivals.register(request("prestock-ok-" + tag, w, leaf, purchaseItem, false)));

        // 品质合格 → 自动转正到登记时的叶仓/库位。
        UUID inspectionId = (UUID) line.get("id");
        inspections.dispose("PURCHASE", receipt, inspectionId,
                new InspectionDispositionRequest("PASS", null, null, "prestock-reg-pass-" + inspectionId));
        assertEquals(0, new BigDecimal("1.25").compareTo(balance(leaf, w.goodsD())));
        assertEquals("R-07", jdbc.queryForObject("SELECT place_snapshot FROM procurement_iqc_stock_in_batch_items WHERE inspection_item_id=?", String.class, inspectionId));
        assertEquals("PRE_STOCKED_AUTO", jdbc.queryForObject("SELECT origin FROM procurement_iqc_stock_in_batches WHERE receipt_id=?", String.class, receipt));
        drainOutbox();
    }

    // ------------------------------------------------------------------ helpers

    private static WarehouseArrivalRegisterRequest request(String key, FullChainEndToEndTest.World w, UUID leaf,
                                                           UUID purchaseItem, boolean stockInFirst) {
        return new WarehouseArrivalRegisterRequest(key, "PURCHASE", BusinessTime.today(), w.supplierId(), leaf,
                w.employeeId(), w.employeeId(), "先入库后检登记",
                List.of(new ArrivalLine(w.goodsD(), new BigDecimal("1.25"), purchaseItem, null, w.unitId(), BigDecimal.ONE,
                        null, "PO-PRESTOCK", null, "R-07")),
                stockInFirst);
    }

    private Case prepare(String type) {
        String tag = "ps-" + UUID.randomUUID().toString().substring(0, 8);
        var fixture = new WarehouseIqcMultiLineFixture(beans, jdbc).prepare(2, 2, tag);
        var masters = new FullChainEndToEndTest();
        beans.autowireBean(masters);
        masters.loginAs(fixture.world().superAdminUserId());
        var rows = fixture.receipts().stream().filter(receipt -> receipt.type().equals(type)).toList();
        return new Case(type, rows.getFirst().id(), rows, fixture.leaves(), fixture.world());
    }

    private record Case(String type, UUID receipt, List<WarehouseIqcScaleFixture.Receipt> rows, List<UUID> leaves,
                        FullChainEndToEndTest.World world) {
    }

    private void drainOutbox() {
        int guard = 0;
        while (outbox.processNext() && guard++ < 200) {
            // 通知投递失败会抛出；这里只要求所有事件(含 PRE_STOCKED 通知)都能被处理完。
        }
    }

    private int events(UUID receiptId, String action) {
        return jdbc.queryForObject("""
                SELECT count(*) FROM procurement_inspection_events event
                JOIN procurement_inspection_items item ON item.id = event.inspection_item_id
                WHERE item.receipt_id = ? AND event.action = ?
                """, Integer.class, receiptId, action);
    }

    private BigDecimal balance(UUID warehouseId, UUID goodsId) {
        BigDecimal value = jdbc.queryForObject(
                "SELECT COALESCE(SUM(qty), 0) FROM stock_balances WHERE warehouse_id = ? AND goods_id = ?",
                BigDecimal.class, warehouseId, goodsId);
        return value == null ? BigDecimal.ZERO : value;
    }

    private static void conflict(Runnable action) {
        assertEquals(ErrorCode.CONFLICT, assertThrows(ApiException.class, action::run).getCode());
    }
}
