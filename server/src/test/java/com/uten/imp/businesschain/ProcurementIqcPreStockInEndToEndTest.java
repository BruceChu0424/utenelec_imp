package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.outbox.BusinessOutboxProcessor;
import com.uten.imp.features.notice.outbox.BusinessOutboxScheduler;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts;
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
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.web.context.WebApplicationContext;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

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
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
})
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@Import(ProductionJdbcMeasurement.Configuration.class)
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
    @Autowired WebApplicationContext web;
    @Autowired ProcurementInspectionService inspections;
    @Autowired ProcurementIqcPreStockInService preStock;
    @Autowired WarehouseQualityResultService qualityResults;
    @Autowired WarehouseArrivalRegistrationService arrivals;
    @Autowired BusinessOutboxProcessor outbox;
    // Keep delivery transactions real while this fixture owns their deterministic scheduling.
    @MockitoBean BusinessOutboxScheduler outboxScheduler;
    @MockitoSpyBean com.uten.imp.features.production.fulfillment.ProductionPurchaseSupplyTransitionService purchase;
    @MockitoSpyBean com.uten.imp.features.production.fulfillment.ProductionSubcontractSupplyTransitionService subcontract;

    @AfterEach
    void cleanup() { SecurityContextHolder.clearContext(); ProductionJdbcMeasurement.end(); }

    @ParameterizedTest
    @ValueSource(strings = {"PURCHASE", "SUBCONTRACT"})
    void automaticStockAndQualityCloseoutReconcileOnceInTheSameTransaction(String type) {
        Case c = prepare(type);
        UUID leaf = c.leaves().getFirst();
        preStock.preStockIn(type, c.receipt(), new PreStockInRequest(c.rows().stream()
                .map(row -> new PreStockInItem(row.inspectionId(), leaf, "CLOSEOUT-01")).toList()));
        var request = new BatchInspectionPassRequest(c.rows().stream().map(row ->
                new BatchInspectionPassRequest.Item(row.inspectionId(), RECEIPT_QTY,
                        "closeout-once-" + row.inspectionId())).toList(), null);
        org.mockito.Mockito.clearInvocations(purchase, subcontract);

        var measured = ProductionJdbcMeasurement.begin();
        inspections.passBatch(type, c.receipt(), request);
        ProductionJdbcMeasurement.end();

        assertEquals(1, measured.commits, "品质、自动入库、正式供给与整单结案仍同事务提交");
        String closure = type.equals("PURCHASE") ? "purchase.order_closure" : "subcontract.order_closure";
        long closureStatements = measured.labelsByFingerprint.entrySet().stream()
                .filter(entry -> closure.equals(entry.getValue()))
                .mapToLong(entry -> measured.fingerprints.getOrDefault(entry.getKey(), 0L)).sum();
        assertEquals(1, closureStatements, "同一命令不能在自动入库和品质结案各重算一次订单");
        UUID batch = jdbc.queryForObject("SELECT id FROM procurement_iqc_stock_in_batches WHERE receipt_id=?",
                UUID.class, c.receipt());
        if (type.equals("PURCHASE")) {
            org.mockito.Mockito.verify(purchase).advanceInspectionStockInState(c.receipt(), batch);
            org.mockito.Mockito.verify(purchase, org.mockito.Mockito.never()).onPurchaseReceiptApproved(c.receipt());
        } else {
            org.mockito.Mockito.verify(subcontract).advanceInspectionStockInState(c.receipt());
            org.mockito.Mockito.verify(subcontract, org.mockito.Mockito.never()).onSubcontractReceiptApproved(c.receipt());
        }
        assertEquals(1, events(c.receipt(), "RECEIPT_RESOLVED"));
        for (var row : c.rows()) {
            assertEquals(0, RECEIPT_QTY.compareTo(balance(leaf, row.goodsId())));
        }
        inspections.passBatch(type, c.receipt(), request);
        assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=?",
                Integer.class, c.receipt()));
        assertEquals(1, events(c.receipt(), "RECEIPT_RESOLVED"));
    }

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
        drainOutbox(c.type(), c.receipt());

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
        drainOutbox(c.type(), c.receipt());

        // ⑤ 出了结论就不能再改上架位置(服务 + 数据库触发器双闸)。
        conflict(() -> preStock.preStockIn("PURCHASE", c.receipt(), new PreStockInRequest(List.of(
                new PreStockInItem(line1.inspectionId(), first, "Z-99")))));
        assertThrows(Exception.class, () -> jdbc.update(
                "UPDATE procurement_inspection_items SET pre_stocked_place='Z-99' WHERE id=?", line1.inspectionId()));

        // ⑥ 仓库合并页：明细带位置、历史带来源、退回案件带位置；无可再上架的行。
        TaskDetail detail = qualityResults.detail("PURCHASE", c.receipt());
        assertEquals(2, detail.lines().size());
        assertTrue(detail.lines().stream().allMatch(line -> line.preStocked() != null));
        assertTrue(detail.lines().stream().allMatch(line -> "CHARGED".equals(line.quantityTranche())));
        for(var line:detail.lines())assertEquals(jdbc.queryForObject(
                "SELECT quantity_tranche FROM procurement_inspection_items WHERE id=? AND receipt_type=? AND receipt_id=?",
                String.class,line.inspectionItemId(),"PURCHASE",c.receipt()),line.quantityTranche());
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
        TaskDetail detail=qualityResults.detail("SUBCONTRACT",c.receipt());
        assertEquals(c.rows().size(),detail.lines().size());
        assertTrue(detail.lines().stream().allMatch(line -> "LEGACY".equals(line.quantityTranche())));
        for(var line:detail.lines())assertEquals(jdbc.queryForObject(
                "SELECT quantity_tranche FROM procurement_inspection_items WHERE id=? AND receipt_type=? AND receipt_id=?",
                String.class,line.inspectionItemId(),"SUBCONTRACT",c.receipt()),line.quantityTranche());
        drainOutbox(c.type(), c.receipt());
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
        drainOutbox("PURCHASE", receipt);
    }

    /**
     * ADR-151 §5：登记实际到货只有一个命令(单张 = 1 组、多选 = N 组)。一个事务里服务端按「订货单 × 入库仓库」
     * 分组建收货单；整批同键重放返回原结果；同键改内容 409；任何一组失败整批不落任何一张。
     */
    @Test
    void batchArrivalGroupsOrderByWarehouseInOneTransactionAndReplaysAsOneCommand() {
        String tag = "pab-" + UUID.randomUUID().toString().substring(0, 8);
        var masters = new FullChainEndToEndTest();
        beans.autowireBean(masters);
        var w = masters.seedWorld(tag);
        masters.loginAs(w.superAdminUserId());
        UUID leaf = UUID.randomUUID();
        UUID leaf2 = UUID.randomUUID();
        jdbc.update("INSERT INTO warehouses(id,parent_id,code,name,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",
                leaf, w.warehouseId(), "PB-L1-" + tag, "批量到货叶仓一");
        jdbc.update("INSERT INTO warehouses(id,parent_id,code,name,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",
                leaf2, w.warehouseId(), "PB-L2-" + tag, "批量到货叶仓二");
        UUID finished = UUID.randomUUID();
        masters.insertGoods(finished, "PBF-" + tag, "批量到货成品", "自制", w.unitId(), w.unitLegacy());
        masters.insertBom(finished, w.goodsD(), "1");
        jdbc.update("UPDATE goods SET default_supplier_id=? WHERE id=?", w.supplierId(), w.goodsD());
        var view = beans.getBean(MaterialAnalysisService.class).preview(new PreviewRequest(null, null, null, w.warehouseId(),
                "batch-arrival-preview-" + tag, List.of(new PreviewItem("OTHER", null, finished, null, w.unitId(),
                        "BATCH-" + tag, "批量到货登记", BusinessTime.today(), new BigDecimal("2.5")))));
        UUID purchaseItem = ReflectionTestUtils.invokeMethod(masters, "approvePurchaseForAnalysis",
                WarehouseIqcScaleFixture.withWarehouse(w, leaf), view, w.goodsD());
        assertNotNull(purchaseItem);
        masters.loginAs(w.superAdminUserId());
        int receiptsBefore = jdbc.queryForObject("SELECT count(*) FROM purchase_receipts WHERE supplier_id=?",
                Integer.class, w.supplierId());

        // 同一张订货单的一行实物分到两个仓：一个命令、一个事务、按仓两张收货单。
        String key = "batch-arrival-" + tag;
        var result = arrivals.registerBatch(batchRequest(key, w, List.of(
                batchLine(w, leaf, purchaseItem, "1.0"), batchLine(w, leaf2, purchaseItem, "0.5"))));
        assertEquals(2, result.groupCount());
        assertFalse(result.replay());
        assertEquals(2, result.items().size());
        assertEquals(Set.of(leaf, leaf2), result.items().stream()
                .map(ProcurementArrivalContracts.WarehouseArrivalBatchRegisterItem::warehouseId).collect(Collectors.toSet()));
        assertTrue(result.items().stream().allMatch(item -> "SUBMITTED_FOR_INSPECTION".equals(item.outcome())));
        assertEquals(receiptsBefore + 2, jdbc.queryForObject("SELECT count(*) FROM purchase_receipts WHERE supplier_id=?",
                Integer.class, w.supplierId()));
        assertEquals(2, jdbc.queryForObject(
                "SELECT count(*) FROM warehouse_arrival_registration_commands WHERE batch_idempotency_key=?",
                Integer.class, key));
        assertEquals(1, jdbc.queryForObject(
                "SELECT count(DISTINCT batch_request_hash) FROM warehouse_arrival_registration_commands WHERE batch_idempotency_key=?",
                Integer.class, key));

        // 丢响应后原样重试：整批重放，收货单不多建。
        var replayed = arrivals.registerBatch(batchRequest(key, w, List.of(
                batchLine(w, leaf, purchaseItem, "1.0"), batchLine(w, leaf2, purchaseItem, "0.5"))));
        assertTrue(replayed.replay());
        assertEquals(result.items().stream().map(ProcurementArrivalContracts.WarehouseArrivalBatchRegisterItem::receiptId).collect(Collectors.toSet()),
                replayed.items().stream().map(ProcurementArrivalContracts.WarehouseArrivalBatchRegisterItem::receiptId).collect(Collectors.toSet()));
        assertEquals(receiptsBefore + 2, jdbc.queryForObject("SELECT count(*) FROM purchase_receipts WHERE supplier_id=?",
                Integer.class, w.supplierId()));
        // 同键改内容：409，什么都不写。
        conflict(() -> arrivals.registerBatch(batchRequest(key, w, List.of(
                batchLine(w, leaf, purchaseItem, "0.9"), batchLine(w, leaf2, purchaseItem, "0.5")))));

        // 整批一个事务：第一组能建、第二组仓库不存在 -> 整批回滚，第一组的收货单也不留。
        UUID missingWarehouse = UUID.fromString("ffffffff-ffff-4fff-bfff-ffffffffffff");
        String broken = "batch-arrival-broken-" + tag;
        assertThrows(RuntimeException.class, () -> arrivals.registerBatch(batchRequest(broken, w, List.of(
                batchLine(w, leaf, purchaseItem, "0.2"), batchLine(w, missingWarehouse, purchaseItem, "0.2")))));
        assertEquals(receiptsBefore + 2, jdbc.queryForObject("SELECT count(*) FROM purchase_receipts WHERE supplier_id=?",
                Integer.class, w.supplierId()));
        assertEquals(0, jdbc.queryForObject(
                "SELECT count(*) FROM warehouse_arrival_registration_commands WHERE batch_idempotency_key=?",
                Integer.class, broken));
        result.items().stream().map(ProcurementArrivalContracts.WarehouseArrivalBatchRegisterItem::receiptId)
                .distinct().forEach(id -> drainOutbox("PURCHASE", id));
    }

    private static ProcurementArrivalContracts.WarehouseArrivalBatchRegisterRequest batchRequest(
            String key, FullChainEndToEndTest.World w, List<ProcurementArrivalContracts.BatchArrivalLine> lines) {
        return new ProcurementArrivalContracts.WarehouseArrivalBatchRegisterRequest(key, BusinessTime.today(),
                w.employeeId(), "批量到货登记", false, false, lines);
    }

    private static ProcurementArrivalContracts.BatchArrivalLine batchLine(FullChainEndToEndTest.World w, UUID warehouse,
                                                                          UUID purchaseItem, String qty) {
        return new ProcurementArrivalContracts.BatchArrivalLine("PURCHASE", warehouse, w.employeeId(), w.goodsD(),
                new BigDecimal(qty), purchaseItem, null, w.unitId(), BigDecimal.ONE, null, "PO-BATCH", null, null, null);
    }

    @Test
    void returnedViewAndSpecialWithoutStockViewNeverAdvertisePreStockCapability() throws Exception {
        Case c = prepare("PURCHASE");
        var masters = new FullChainEndToEndTest();
        beans.autowireBean(masters);
        String tag = UUID.randomUUID().toString().substring(0, 8);
        UUID returnReader = masters.createUserWithPerms(c.world(), "prestock-return-reader-" + tag,
                "warehouse_iqc_return:view", "warehouse_iqc_stock_in:before_inspection");
        masters.loginAs(returnReader);
        TaskDetail denied = qualityResults.detail("PURCHASE", c.receipt());
        assertFalse(denied.allowedActions().contains(TaskDetail.ACTION_PRE_STOCK_IN));
        assertFalse(nativeDetailPreStockCapability(c));
        UUID authorized = masters.createUserWithPerms(c.world(), "prestock-view-reader-" + tag,
                "warehouse_iqc_stock_in:view", "warehouse_iqc_stock_in:before_inspection");
        masters.loginAs(authorized);
        assertTrue(qualityResults.detail("PURCHASE", c.receipt()).allowedActions().contains(TaskDetail.ACTION_PRE_STOCK_IN));
        assertTrue(nativeDetailPreStockCapability(c));
        masters.loginAs(authorized);
        var readonly = readonlyWarehouseActor(SecurityContextHolder.getContext().getAuthentication(),
                c.world().superAdminUserId());
        var beforeReadonly = ordinaryWarehouseFacts(c);
        nativeWarehousePost(nativeWarehouseMvc(), "/api/warehouse/iqc-stock-ins/PURCHASE/" + c.receipt() + "/pre-stock-in",
                new PreStockInRequest(List.of(new PreStockInItem(c.rows().getFirst().inspectionId(),
                        c.leaves().getFirst(), "QA-READONLY-01"))), readonly, 403);
        assertEquals(beforeReadonly, ordinaryWarehouseFacts(c));
        SecurityContextHolder.getContext().setAuthentication(readonly);
        assertFalse(nativeDetailPreStockCapability(c), "readonly actual principal cannot advertise an up-shelf write");
        UUID baseOnly = masters.createUserWithPerms(c.world(), "prestock-base-reader-" + tag,
                "warehouse_iqc_stock_in:view");
        masters.loginAs(baseOnly);
        assertFalse(qualityResults.detail("PURCHASE", c.receipt()).allowedActions().contains(TaskDetail.ACTION_PRE_STOCK_IN));
        assertFalse(nativeDetailPreStockCapability(c));
    }

    private boolean nativeDetailPreStockCapability(Case c) throws Exception {
        var mvc = MockMvcBuilders.webAppContextSetup(web)
                .apply(org.springframework.security.test.web.servlet.setup.SecurityMockMvcConfigurers.springSecurity()).build();
        var authentication = SecurityContextHolder.getContext().getAuthentication();
        var result = mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders
                        .get("/api/warehouse/quality-results/PURCHASE/" + c.receipt())
                        .with(org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors
                                .authentication(authentication)))
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.status().isOk())
                .andReturn();
        var json = beans.getBean(com.fasterxml.jackson.databind.ObjectMapper.class)
                .readTree(result.getResponse().getContentAsString());
        assertEquals(c.receipt().toString(), json.path("receiptId").asText());
        assertTrue(json.path("lines").size() > 0);
        for (var action : json.path("allowedActions")) {
            if (TaskDetail.ACTION_PRE_STOCK_IN.equals(action.asText())) return true;
        }
        return false;
    }

    @Test
    void ordinaryConfirmCapabilityMatchesNativeHttpViewAndCommandAuthorities() throws Exception {
        Case c = prepareMixedOrdinaryReceipt();
        var mvc = nativeWarehouseMvc();
        var masters = new FullChainEndToEndTest();
        beans.autowireBean(masters);
        String tag = UUID.randomUUID().toString().substring(0, 8);
        UUID missingView = masters.createUserWithPerms(c.world(), "iqc-confirm-no-view-" + tag,
                "warehouse_iqc_return:view", "warehouse_iqc_stock_in:confirm");
        masters.loginAs(missingView);
        var deniedActor = SecurityContextHolder.getContext().getAuthentication();
        var denied = nativeQualityDetail(mvc, c, deniedActor);
        assertFalse(denied.path("items").isEmpty(), "actual qualified slice is still available");
        var request = ordinaryConfirmRequest(denied, "iqc-authority-confirm-" + tag);
        var before = ordinaryWarehouseFacts(c);
        nativeWarehousePost(mvc, "/api/warehouse/iqc-stock-ins/PURCHASE/" + c.receipt() + "/confirm",
                request, deniedActor, 403);
        assertEquals(before, ordinaryWarehouseFacts(c), "missing base view must write no business facts");

        UUID reader = masters.createUserWithPerms(c.world(), "iqc-confirm-reader-" + tag,
                "warehouse_iqc_stock_in:view");
        masters.loginAs(reader);
        assertFalse(jsonAction(nativeQualityDetail(mvc, c,
                SecurityContextHolder.getContext().getAuthentication()), "CONFIRM"));

        UUID authorized = masters.createUserWithPerms(c.world(), "iqc-confirm-writer-" + tag,
                "warehouse_iqc_stock_in:view", "warehouse_iqc_stock_in:confirm");
        masters.loginAs(authorized);
        var actor = SecurityContextHolder.getContext().getAuthentication();
        var allowed = nativeQualityDetail(mvc, c, actor);
        assertTrue(jsonAction(allowed, "CONFIRM"));
        var readonly = readonlyWarehouseActor(actor, c.world().superAdminUserId());
        var readOnlyBefore = ordinaryWarehouseFacts(c);
        nativeWarehousePost(mvc, "/api/warehouse/iqc-stock-ins/PURCHASE/" + c.receipt() + "/confirm",
                request, readonly, 403);
        assertEquals(readOnlyBefore, ordinaryWarehouseFacts(c));
        var readonlyMerged = nativeQualityDetail(mvc, c, readonly);
        var readonlyNative = nativeWarehouseGet(mvc,
                "/api/warehouse/iqc-stock-ins/PURCHASE/" + c.receipt(), readonly);
        org.junit.jupiter.api.Assertions.assertAll(
                () -> assertFalse(jsonAction(denied, "CONFIRM"), "return-view cannot advertise a stock-view command"),
                () -> assertFalse(jsonAction(readonlyMerged, "CONFIRM"), "merged readonly actor cannot advertise confirm"),
                () -> assertFalse(jsonAction(readonlyNative, "CONFIRM"), "native readonly detail cannot advertise confirm"));

        var successful = ordinaryConfirmRequest(allowed, "iqc-authority-confirm-ok-" + tag);
        nativeWarehousePost(mvc, "/api/warehouse/iqc-stock-ins/PURCHASE/" + c.receipt() + "/confirm",
                successful, actor, 200);
        assertEquals(0, new BigDecimal("0.75").compareTo(jdbc.queryForObject(
                "SELECT warehouse_stocked_base_qty FROM procurement_inspection_items WHERE id=?",
                BigDecimal.class, c.rows().getFirst().inspectionId())));
        var committed = ordinaryWarehouseFacts(c);
        nativeWarehousePost(mvc, "/api/warehouse/iqc-stock-ins/PURCHASE/" + c.receipt() + "/confirm",
                successful, actor, 200);
        assertEquals(committed, ordinaryWarehouseFacts(c), "actual native retry must not post twice");
    }

    @Test
    void physicalReturnCapabilityMatchesNativeHttpReturnViewAndCommandAuthorities() throws Exception {
        Case c = prepareMixedOrdinaryReceipt();
        var mvc = nativeWarehouseMvc();
        var masters = new FullChainEndToEndTest();
        beans.autowireBean(masters);
        String tag = UUID.randomUUID().toString().substring(0, 8);
        UUID missingView = masters.createUserWithPerms(c.world(), "iqc-return-no-view-" + tag,
                "warehouse_iqc_stock_in:view", "procurement_iqc_rejection:record_return");
        masters.loginAs(missingView);
        var deniedActor = SecurityContextHolder.getContext().getAuthentication();
        var denied = nativeQualityDetail(mvc, c, deniedActor);
        assertEquals(1, denied.path("rejections").size(), "real resolved rejection/outbox projection");
        var rejection = denied.path("rejections").get(0);
        UUID caseId = UUID.fromString(rejection.path("id").asText());
        var request = new com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RecordReturnRequest(
                rejection.path("rowVersion").asLong(), UUID.randomUUID(), "QA-RETURN-" + tag,
                BusinessTime.today(), "actual authority contract");
        var before = ordinaryWarehouseFacts(c);
        nativeWarehousePost(mvc, "/api/warehouse/iqc-returns/" + caseId + "/record-return",
                request, deniedActor, 403);
        assertEquals(before, ordinaryWarehouseFacts(c), "missing return view must write no business facts");
        UUID sparse = masters.createUserWithPerms(c.world(), "iqc-return-sparse-" + tag,
                "warehouse_iqc_return:view");
        masters.loginAs(sparse);
        var sparseUser = (com.uten.imp.security.AuthUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        var sparsePrincipal = new com.uten.imp.security.AuthUser(sparseUser.getId(), sparseUser.getEmployeeId(),
                sparseUser.getLoginAccount(), sparseUser.getPermissions(), false, true, true);
        var sparseActor = new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(
                sparsePrincipal, null, sparsePrincipal.getAuthorities());
        assertTrue(sparsePrincipal.isSuperAdmin());
        assertFalse(sparsePrincipal.getPermissions().contains("procurement_iqc_rejection:record_return"));
        var sparseView = nativeWarehouseGet(mvc, "/api/warehouse/iqc-returns/" + caseId, sparseActor);
        var sparseBefore = ordinaryWarehouseFacts(c);
        nativeWarehousePost(mvc, "/api/warehouse/iqc-returns/" + caseId + "/record-return", request, sparseActor, 403);
        assertEquals(sparseBefore, ordinaryWarehouseFacts(c));
        org.junit.jupiter.api.Assertions.assertAll(
                () -> assertFalse(rejection.path("canRecordReturn").asBoolean(), "stock-view cannot advertise return-view command"),
                () -> assertFalse(jsonAction(sparseView, "RECORD_RETURN"), "standalone SA flag cannot replace native raw record authority"));

        UUID reader = masters.createUserWithPerms(c.world(), "iqc-return-reader-" + tag,
                "warehouse_iqc_return:view");
        masters.loginAs(reader);
        assertFalse(nativeQualityDetail(mvc, c, SecurityContextHolder.getContext().getAuthentication())
                .path("rejections").get(0).path("canRecordReturn").asBoolean());

        UUID authorized = masters.createUserWithPerms(c.world(), "iqc-return-writer-" + tag,
                "warehouse_iqc_return:view", "procurement_iqc_rejection:record_return");
        masters.loginAs(authorized);
        var actor = SecurityContextHolder.getContext().getAuthentication();
        assertTrue(jsonAction(nativeWarehouseGet(mvc, "/api/warehouse/iqc-returns/" + caseId, actor), "RECORD_RETURN"));
        assertTrue(nativeQualityDetail(mvc, c, actor).path("rejections").get(0)
                .path("canRecordReturn").asBoolean());
        var readonly = readonlyWarehouseActor(actor, c.world().superAdminUserId());
        var readOnlyBefore = ordinaryWarehouseFacts(c);
        nativeWarehousePost(mvc, "/api/warehouse/iqc-returns/" + caseId + "/record-return",
                request, readonly, 403);
        assertEquals(readOnlyBefore, ordinaryWarehouseFacts(c));
        org.junit.jupiter.api.Assertions.assertAll(
                () -> assertFalse(nativeQualityDetail(mvc, c, readonly).path("rejections").get(0)
                        .path("canRecordReturn").asBoolean()),
                () -> assertFalse(jsonAction(nativeWarehouseGet(mvc, "/api/warehouse/iqc-returns/" + caseId, readonly), "RECORD_RETURN")));

        nativeWarehousePost(mvc, "/api/warehouse/iqc-returns/" + caseId + "/record-return",
                request, actor, 200);
        assertNotNull(jdbc.queryForObject("SELECT return_recorded_at FROM procurement_iqc_rejection_cases WHERE id=?",
                java.sql.Timestamp.class, caseId));
        var committed = ordinaryWarehouseFacts(c);
        nativeWarehousePost(mvc, "/api/warehouse/iqc-returns/" + caseId + "/record-return",
                request, actor, 200);
        assertEquals(committed, ordinaryWarehouseFacts(c), "actual return retry must not repeat effects");
    }

    private Case prepareMixedOrdinaryReceipt() {
        return prepareMixedOrdinaryReceipt(true);
    }

    private Case prepareMixedOrdinaryReceipt(boolean deliver) {
        Case c = prepare("PURCHASE");
        inspections.decideBatch(c.type(), c.receipt(), new BatchInspectionDecideRequest(List.of(
                new BatchInspectionDecideRequest.Item(c.rows().getFirst().inspectionId(), RECEIPT_QTY,
                        new BigDecimal("0.75"), new BigDecimal("0.50"), "authority-mixed-" + UUID.randomUUID())),
                "genuine mixed quality conclusion"));
        if (deliver) drainOutbox(c.type(), c.receipt());
        return c;
    }

    @Test
    void receiptOutboxCompletionWaitsForAClaimedRejectionInsteadOfTreatingSkipLockedAsIdle() throws Exception {
        Case c = prepareMixedOrdinaryReceipt(false);
        UUID inspectionId = c.rows().getFirst().inspectionId();
        UUID eventId = jdbc.queryForObject("""
                SELECT id FROM business_outbox
                WHERE event_type='PROCUREMENT_IQC_REJECTION_DETECTED' AND aggregate_id=? AND status=0
                """, UUID.class, inspectionId);
        assertNotNull(eventId);
        var worker = java.util.concurrent.Executors.newSingleThreadExecutor(Thread.ofPlatform()
                .name("iqc-fixture-delivery").inheritInheritableThreadLocals(false).factory());
        try (var claim = jdbc.getDataSource().getConnection()) {
            claim.setAutoCommit(false);
            try (var lock = claim.prepareStatement("SELECT id FROM business_outbox WHERE id=? FOR UPDATE")) {
                lock.setObject(1, eventId);
                try (var locked = lock.executeQuery()) { assertTrue(locked.next()); }
            }
            try {
                boolean noClaimableEvent = false;
                for (int index = 0; index < 200; index++) {
                    if (!outbox.processNext()) {
                        noClaimableEvent = true;
                        break;
                    }
                }
                assertTrue(noClaimableEvent, "real SKIP LOCKED can report idle while the target event is claimed");
                assertEquals(0, jdbc.queryForObject("SELECT status FROM business_outbox WHERE id=?", Integer.class, eventId));
                assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM procurement_iqc_rejection_cases WHERE inspection_item_id=?",
                        Integer.class, inspectionId));
                assertTrue(qualityResults.detail(c.type(), c.receipt()).rejections().isEmpty());

                var started = new java.util.concurrent.CountDownLatch(1);
                var completion = worker.submit(() -> {
                    started.countDown();
                    drainOutbox(c.type(), c.receipt());
                });
                assertTrue(started.await(2, java.util.concurrent.TimeUnit.SECONDS));
                assertThrows(java.util.concurrent.TimeoutException.class,
                        () -> completion.get(200, java.util.concurrent.TimeUnit.MILLISECONDS),
                        "delivery completion must wait for the receipt's durable projection, not global idle");
                assertEquals(0, jdbc.queryForObject("SELECT status FROM business_outbox WHERE id=?", Integer.class, eventId));
                claim.commit();
                completion.get(20, java.util.concurrent.TimeUnit.SECONDS);
                assertEquals(1, jdbc.queryForObject("SELECT status FROM business_outbox WHERE id=?", Integer.class, eventId));
                assertEquals(1, qualityResults.detail(c.type(), c.receipt()).rejections().size());
            } finally {
                claim.rollback();
            }
        } finally {
            worker.shutdownNow();
            assertTrue(worker.awaitTermination(5, java.util.concurrent.TimeUnit.SECONDS));
        }
    }

    private org.springframework.test.web.servlet.MockMvc nativeWarehouseMvc() {
        return MockMvcBuilders.webAppContextSetup(web)
                .apply(org.springframework.security.test.web.servlet.setup.SecurityMockMvcConfigurers.springSecurity()).build();
    }

    private com.fasterxml.jackson.databind.JsonNode nativeQualityDetail(
            org.springframework.test.web.servlet.MockMvc mvc, Case c,
            org.springframework.security.core.Authentication actor) throws Exception {
        return nativeWarehouseGet(mvc, "/api/warehouse/quality-results/PURCHASE/" + c.receipt(), actor);
    }

    private com.fasterxml.jackson.databind.JsonNode nativeWarehouseGet(
            org.springframework.test.web.servlet.MockMvc mvc, String path,
            org.springframework.security.core.Authentication actor) throws Exception {
        var response = mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders
                        .get(path)
                        .with(org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication(actor)))
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.status().isOk()).andReturn();
        return beans.getBean(com.fasterxml.jackson.databind.ObjectMapper.class)
                .readTree(response.getResponse().getContentAsString());
    }

    private void nativeWarehousePost(org.springframework.test.web.servlet.MockMvc mvc, String path, Object command,
                                     org.springframework.security.core.Authentication actor, int expectedStatus) throws Exception {
        var result = mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post(path)
                        .with(org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication(actor))
                        .contentType(org.springframework.http.MediaType.APPLICATION_JSON)
                        .content(beans.getBean(com.fasterxml.jackson.databind.ObjectMapper.class).writeValueAsString(command)))
                .andReturn();
        assertEquals(expectedStatus, result.getResponse().getStatus(),
                "native " + path + ": " + result.getResponse().getContentAsString());
    }

    private com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest ordinaryConfirmRequest(
            com.fasterxml.jackson.databind.JsonNode detail, String key) {
        var slice = detail.path("items").get(0);
        return new com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest(key, List.of(
                new com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmItem(
                        UUID.fromString(slice.path("passEventId").asText()), slice.path("remainingBaseQty").decimalValue(),
                        slice.path("remainingBaseQty").decimalValue(), "QA-CONFIRM-01",
                        UUID.fromString(slice.path("warehouseId").asText()))));
    }

    private static boolean jsonAction(com.fasterxml.jackson.databind.JsonNode detail, String expected) {
        for (var action : detail.path("allowedActions")) if (expected.equals(action.asText())) return true;
        return false;
    }

    private static org.springframework.security.core.Authentication readonlyWarehouseActor(
            org.springframework.security.core.Authentication actor, UUID impersonator) {
        var user = (com.uten.imp.security.AuthUser) actor.getPrincipal();
        var readonly = new com.uten.imp.security.AuthUser(user.getId(), user.getEmployeeId(), user.getLoginAccount(),
                user.getPermissions(), false, true, user.isSuperAdmin(), false, impersonator);
        return new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(readonly, null, readonly.getAuthorities());
    }

    private Map<String, Object> ordinaryWarehouseFacts(Case c) {
        return Map.of(
                "inspection", jdbc.queryForList("SELECT to_jsonb(item)::text FROM procurement_inspection_items item WHERE receipt_id=? ORDER BY id", String.class, c.receipt()),
                "stockBatches", jdbc.queryForObject("SELECT count(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=?", Integer.class, c.receipt()),
                "inspectionEvents", jdbc.queryForObject("SELECT count(*) FROM procurement_inspection_events event JOIN procurement_inspection_items item ON item.id=event.inspection_item_id WHERE item.receipt_id=?", Integer.class, c.receipt()),
                "rejections", jdbc.queryForList("SELECT to_jsonb(rejection)::text FROM procurement_iqc_rejection_cases rejection WHERE receipt_id=? ORDER BY id", String.class, c.receipt()),
                "stockQty", balance(c.leaves().getFirst(), c.rows().getFirst().goodsId()));
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

    private void drainOutbox(String receiptType, UUID receiptId) {
        long deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(20);
        while (true) {
            var pending = jdbc.queryForList("""
                    SELECT event.id,event.event_type,event.status
                    FROM business_outbox event
                    WHERE event.status<>1 AND (
                        event.aggregate_id=? OR event.payload->>'receiptId'=? OR EXISTS (
                            SELECT 1 FROM procurement_inspection_items inspection
                            WHERE inspection.receipt_type=? AND inspection.receipt_id=?
                              AND (inspection.id=event.aggregate_id OR EXISTS (
                                  SELECT 1 FROM procurement_inspection_events resolution
                                  WHERE resolution.inspection_item_id=inspection.id AND resolution.id=event.aggregate_id))))
                    ORDER BY event.created_at,event.id
                    """, receiptId, receiptId.toString(), receiptType, receiptId);
            var missingRejections = jdbc.queryForList("""
                    SELECT inspection.id FROM procurement_inspection_items inspection
                    WHERE inspection.receipt_type=? AND inspection.receipt_id=?
                      AND inspection.status IN ('PARTIAL','RESOLVED') AND inspection.failed_base_qty>0
                      AND NOT EXISTS (SELECT 1 FROM procurement_iqc_rejection_cases rejection
                          WHERE rejection.inspection_item_id=inspection.id AND NOT rejection.is_deleted)
                    """, UUID.class, receiptType, receiptId);
            if (pending.isEmpty() && missingRejections.isEmpty()) return;
            if (System.nanoTime() >= deadline) {
                throw new AssertionError("Receipt outbox delivery did not commit: " + receiptType + "/" + receiptId
                        + "; pending=" + pending + "; missingRejections=" + missingRejections);
            }
            // SKIP LOCKED false says nothing about a sibling worker's uncommitted projection.
            if (!outbox.processNext()) {
                java.util.concurrent.locks.LockSupport.parkNanos(java.util.concurrent.TimeUnit.MILLISECONDS.toNanos(10));
                if (Thread.currentThread().isInterrupted()) throw new AssertionError("Receipt outbox delivery interrupted");
            }
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
