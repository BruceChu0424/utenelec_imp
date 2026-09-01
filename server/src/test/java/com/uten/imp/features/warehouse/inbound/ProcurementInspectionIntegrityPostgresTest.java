package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.ProcurementInspectionPort;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmItem;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmResult;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Real PostgreSQL/service proof for deterministic per-PASS formal supply and
 * whole-receipt IQC closure. FAIL quantities remain quality evidence only:
 * they never enter stock or any production reservation, receipt allocation or
 * DRAW.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.MOCK,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.policy-intelligence.enabled=false",
                "uten.features.goods-owner-scope-enabled=false",
                "uten.jwt.secret=iqc-integrity-jwt-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=iqc-integrity-pgp-key-test-only-0123456789",
                "uten.crypto.hmac-key=iqc-integrity-hmac-key-test-only",
                "uten.bootstrap.admin-login=iqc-bootstrap-admin-test",
                "uten.bootstrap.admin-password=IqcIntegrityAdminPass-1!"
        })
class ProcurementInspectionIntegrityPostgresTest {

    private static final java.util.concurrent.atomic.AtomicInteger BUSINESS_IDENTIFIER_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @DynamicPropertySource
    static void registerDataSource(DynamicPropertyRegistry registry) {
        POSTGRES.start();
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }

    @Autowired private JdbcTemplate jdbc;
    @Autowired private TransactionTemplate transactions;
    @Autowired private ProcurementInspectionService inspectionService;
    @Autowired private ProcurementIqcStockInService stockInService;
    @Autowired private WarehouseQualityResultService qualityResultService;
    @Autowired private ProductionSupplyTransitionPort productionSupply;
    @Autowired private TxSessionVars tx;

    @AfterEach
    void clearSecurity() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void partialPassOnlyQueuesWarehouseThenPartialStockInReplaysAndReversesExactly() {
        ReceiptFixture receipt = seedReceipt(
                ProcurementInspectionPort.PURCHASE, 1, "10", "100");
        InspectionLine line = receipt.lines().getFirst();
        ProductionStockFactCounts stockFactsBefore = productionStockFactCounts();
        login("partial-pass-fail");

        inspectionService.dispose(receipt.type(), receipt.id(), line.inspectionItemId(),
                disposition("PASS", "6", "partial-pass-0001"));
        assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "0");
        assertQuantity(stockedProjection(line.inspectionItemId()), "0");
        assertThat(movementCount(receipt.id())).isZero();
        assertProductionStockFactsUnchanged(stockFactsBefore);

        inspectionService.dispose(receipt.type(), receipt.id(), line.inspectionItemId(),
                disposition("FAIL", "4", "partial-fail-0001"));
        assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "0");
        assertThat(receiptEventCount(receipt, "RECEIPT_RESOLVED")).isEqualTo(1L);
        assertThat(receiptEventCount(receipt, "PRODUCTION_WOKEN")).isZero();
        assertInspection(line.inspectionItemId(), "RESOLVED", "6", "4");
        assertProductionStockFactsUnchanged(stockFactsBefore);

        UUID passEventId = passEventId(line.inspectionItemId());
        loginCurrentEmployee("partial-stock-in");
        ConfirmRequest first = stockInRequest(
                passEventId, "2", "6", "iqc-stock-partial-0001", "A01-01");
        ConfirmResult firstResult = stockInService.confirm(
                receipt.type(), receipt.id(), first);
        assertThat(firstResult.replayed()).isFalse();
        assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "2");
        assertQuantity(stockedProjection(line.inspectionItemId()), "2");
        assertThat(stockInItemCount(receipt.id())).isEqualTo(1L);

        ConfirmResult replay = stockInService.confirm(receipt.type(), receipt.id(), first);
        assertThat(replay.replayed()).isTrue();
        assertThat(replay.batchId()).isEqualTo(firstResult.batchId());
        assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "2");
        assertThat(stockInItemCount(receipt.id())).isEqualTo(1L);
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> stockInService.confirm(
                        receipt.type(), receipt.id(),
                        stockInRequest(passEventId, "1", "4",
                                "iqc-stock-partial-0001", "A01-02")))
                .isInstanceOf(ApiException.class);

        stockInService.confirm(
                receipt.type(), receipt.id(),
                stockInRequest(passEventId, "4", "4",
                        "iqc-stock-partial-0002", "A01-02"));
        assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "6");
        assertQuantity(stockedProjection(line.inspectionItemId()), "6");
        assertThat(stockInItemCount(receipt.id())).isEqualTo(2L);

        transactions.executeWithoutResult(ignored -> inspectionService.reverseResolvedStock(
                receipt.type(), receipt.id(), OffsetDateTime.now()));

        assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "0");
        assertInspection(line.inspectionItemId(), "REVERSED", "0", "0");
        assertQuantity(movementTotal(receipt.id(), (short) 1, "qty"), "6");
        assertQuantity(movementTotal(receipt.id(), (short) -1, "qty"), "6");
        assertQuantity(movementTotal(receipt.id(), (short) 1, "amount_local"), "60");
        assertQuantity(movementTotal(receipt.id(), (short) -1, "amount_local"), "60");
        assertThat(receiptEventCount(receipt, "PASS")).isEqualTo(1L);
        assertThat(receiptEventCount(receipt, "FAIL")).isEqualTo(1L);
        assertThat(receiptEventCount(receipt, "RECEIPT_REVERSED")).isEqualTo(1L);
    }

    @Test
    void qualityPassNeverCreatesFormalSupplyBeforeWarehouseStockIn() {
        ProductionIqcFixture fixture = seedProductionIqcReceipt();
        ReceiptFixture receipt = fixture.receipt();
        InspectionLine productionLine = receipt.lines().get(0);
        InspectionLine unrelatedLine = receipt.lines().get(1);
        loginCurrentEmployee("partial-formal-supply");

        InspectionDispositionRequest firstPass =
                disposition("PASS", "4", "formal-pass-0001");
        inspectionService.dispose(
                receipt.type(), receipt.id(), productionLine.inspectionItemId(), firstPass);

        assertInspection(productionLine.inspectionItemId(), "PARTIAL", "4", "0");
        assertInspection(unrelatedLine.inspectionItemId(), "PENDING", "0", "0");
        assertThat(segmentStatus(fixture.segmentId())).isEqualTo("WAITING");
        assertQuantity(pegConsumed(fixture.orderPegId()), "0");
        assertQuantity(activeReceiptAllocationQty(receipt.id()), "0");
        assertThat(activeReceiptAllocationCount(receipt.id())).isZero();
        assertThat(activeProductionReservationCount(fixture.demandId())).isZero();
        assertThat(activeDrawCount(fixture.segmentId())).isZero();
        assertQuantity(stockQty(receipt.warehouseId(), productionLine.goodsId()), "0");
        assertThat(receiptEventCount(receipt, "PRODUCTION_WOKEN")).isZero();

        // Replaying the quality command remains quality-only and does not create
        // stock, reservations or production supply.
        inspectionService.dispose(
                receipt.type(), receipt.id(), productionLine.inspectionItemId(), firstPass);
        assertQuantity(activeReceiptAllocationQty(receipt.id()), "0");
        assertQuantity(stockQty(receipt.warehouseId(), productionLine.goodsId()), "0");

        // Later quality decisions may close the receipt, but closure still does
        // not create usable stock, reservations, DRAW or segment readiness.
        inspectionService.dispose(
                receipt.type(), receipt.id(), productionLine.inspectionItemId(),
                disposition("FAIL", "2", "formal-fail-0001"));
        assertInspection(productionLine.inspectionItemId(), "RESOLVED", "4", "2");
        assertThat(receiptEventCount(receipt, "PRODUCTION_WOKEN")).isZero();

        inspectionService.dispose(
                receipt.type(), receipt.id(), unrelatedLine.inspectionItemId(),
                disposition("PASS", null, "unrelated-pass-0001"));
        assertInspection(unrelatedLine.inspectionItemId(), "RESOLVED", "3", "0");
        assertThat(receiptEventCount(receipt, "RECEIPT_RESOLVED")).isEqualTo(1L);
        assertThat(receiptEventCount(receipt, "PRODUCTION_WOKEN")).isZero();
        assertQuantity(activeReceiptAllocationQty(receipt.id()), "0");
        assertThat(activeReceiptAllocationCount(receipt.id())).isZero();
        assertThat(activeProductionReservationCount(fixture.demandId())).isZero();
        assertThat(activeDrawCount(fixture.segmentId())).isZero();
        assertThat(segmentStatus(fixture.segmentId())).isEqualTo("WAITING");
        assertQuantity(pegConsumed(fixture.orderPegId()), "0");
        assertQuantity(stockQty(receipt.warehouseId(), productionLine.goodsId()), "0");
        assertQuantity(stockQty(receipt.warehouseId(), unrelatedLine.goodsId()), "0");
    }

    @Test
    void procurementOrderClosesOnlyAfterThePassedQuantityIsWarehouseStocked() {
        ProductionIqcFixture fixture = seedProductionIqcReceipt();
        InspectionLine productionLine = fixture.receipt().lines().getFirst();
        loginCurrentEmployee("order-close-quality");
        inspectionService.dispose(
                fixture.receipt().type(), fixture.receipt().id(),
                productionLine.inspectionItemId(),
                disposition("PASS", null, "order-close-pass-0001"));

        assertThat(jdbc.queryForObject("""
                SELECT is_closed FROM purchase_orders WHERE id=?
                """, Boolean.class, fixture.orderId())).isFalse();

        UUID passEventId = passEventId(productionLine.inspectionItemId());
        loginCurrentEmployee("order-close-warehouse");
        stockInService.confirm(
                fixture.receipt().type(), fixture.receipt().id(),
                stockInRequest(passEventId, "6", "6",
                        "order-close-stock-in-0001", "CLOSE-01"));

        assertThat(jdbc.queryForObject("""
                SELECT is_closed FROM purchase_orders WHERE id=?
                """, Boolean.class, fixture.orderId())).isTrue();
    }

    @Test
    void fullSubcontractFailClosesAndRefreshesWithoutUsableOrReservedStock() {
        ReceiptFixture receipt = seedReceipt(
                ProcurementInspectionPort.SUBCONTRACT, 1, "10", "100");
        InspectionLine line = receipt.lines().getFirst();
        ProductionStockFactCounts stockFactsBefore = productionStockFactCounts();
        login("full-subcontract-fail");

        inspectionService.dispose(receipt.type(), receipt.id(), line.inspectionItemId(),
                disposition("FAIL", null, "full-fail-0001"));

        assertInspection(line.inspectionItemId(), "RESOLVED", "0", "10");
        assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "0");
        assertThat(movementCount(receipt.id())).isZero();
        assertThat(receiptEventCount(receipt, "RECEIPT_RESOLVED")).isEqualTo(1L);
        assertThat(receiptEventCount(receipt, "PRODUCTION_WOKEN")).isZero();
        assertProductionStockFactsUnchanged(stockFactsBefore);
    }

    @Test
    void subcontractPassNeedsASeparateWarehouseConfirmationBeforeStockExists() {
        ReceiptFixture receipt = seedReceipt(
                ProcurementInspectionPort.SUBCONTRACT, 1, "10", "100");
        InspectionLine line = receipt.lines().getFirst();
        login("subcontract-pass-quality");

        inspectionService.dispose(
                receipt.type(), receipt.id(), line.inspectionItemId(),
                disposition("PASS", null, "subcontract-pass-0001"));
        assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "0");
        assertQuantity(stockedProjection(line.inspectionItemId()), "0");

        UUID passEventId = passEventId(line.inspectionItemId());
        loginCurrentEmployee("subcontract-pass-warehouse");
        stockInService.confirm(
                receipt.type(), receipt.id(),
                stockInRequest(
                        passEventId, "10", "10",
                        "subcontract-stock-in-0001", "SC-A01"));

        assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "10");
        assertQuantity(stockedProjection(line.inspectionItemId()), "10");
        assertThat(stockInItemCount(receipt.id())).isEqualTo(1L);
        assertThat(movementCount(receipt.id())).isEqualTo(1L);
        assertQuantity(movementTotal(receipt.id(), (short) 1, "amount_local"), "100");
    }

    @Test
    void employeeWhoReleasedPassCanStillConfirmInSoloMaintenance() {
        ReceiptFixture receipt = seedReceipt(
                ProcurementInspectionPort.PURCHASE, 1, "10", "100");
        InspectionLine line = receipt.lines().getFirst();
        AuthUser sameActor = createWarehouseActor("same-actor-quality-warehouse");
        authenticate(sameActor);

        inspectionService.dispose(
                receipt.type(), receipt.id(), line.inspectionItemId(),
                disposition("PASS", null, "same-actor-pass-0001"));
        UUID passEventId = passEventId(line.inspectionItemId());

        // 单人维护：同人放行不再被硬拒；合并页详情保留 containsOwnRelease 标记
        // 供前端复核提示，且允许动作照常开放。
        assertThat(stockInService.detail(receipt.type(), receipt.id()).allowedActions())
                .contains("CONFIRM");
        assertThat(qualityResultService.detail(receipt.type(), receipt.id())
                .containsOwnRelease()).isTrue();
        assertThat(qualityResultService.detail(receipt.type(), receipt.id())
                .allowedActions()).contains("CONFIRM");

        stockInService.confirm(
                receipt.type(), receipt.id(),
                stockInRequest(passEventId, "10", "10",
                        "same-actor-stock-0001", "SAME-01"));
        assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "10");
        assertThat(stockInBatchCount(receipt.id())).isEqualTo(1L);
    }

    @Test
    void twoPassSlicesOfOneInspectionCanStockInTogetherOnce() {
        ReceiptFixture receipt = seedReceipt(
                ProcurementInspectionPort.PURCHASE, 1, "10", "100");
        InspectionLine line = receipt.lines().getFirst();
        login("same-inspection-two-pass-quality");
        inspectionService.dispose(
                receipt.type(), receipt.id(), line.inspectionItemId(),
                disposition("PASS", "4", "same-inspection-pass-0001"));
        inspectionService.dispose(
                receipt.type(), receipt.id(), line.inspectionItemId(),
                disposition("PASS", "6", "same-inspection-pass-0002"));
        List<UUID> passEventIds = passEventIds(line.inspectionItemId());
        assertThat(passEventIds).hasSize(2);

        loginCurrentEmployee("same-inspection-two-pass-warehouse");
        stockInService.confirm(
                receipt.type(), receipt.id(),
                new ConfirmRequest(
                        "same-inspection-stock-0001",
                        List.of(
                                new ConfirmItem(
                                        passEventIds.get(0), decimal("4"),
                                        decimal("4"), "MULTI-01"),
                                new ConfirmItem(
                                        passEventIds.get(1), decimal("6"),
                                        decimal("6"), "MULTI-01"))));

        assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "10");
        assertQuantity(stockedProjection(line.inspectionItemId()), "10");
        assertThat(stockInBatchCount(receipt.id())).isEqualTo(1L);
        assertThat(stockInItemCount(receipt.id())).isEqualTo(2L);
        assertQuantity(movementTotal(receipt.id(), (short) 1, "amount_local"), "100");
    }

    @Test
    void concurrentLastQualityLinesSerializeToOneTruthfulReceiptResolution() throws Exception {
        ReceiptFixture receipt = seedReceipt(
                ProcurementInspectionPort.PURCHASE, 2, "10", "100");
        CountDownLatch start = new CountDownLatch(1);
        ExecutorService executor = Executors.newFixedThreadPool(2);
        List<Future<?>> futures = new ArrayList<>();
        try {
            for (int i = 0; i < receipt.lines().size(); i++) {
                int lineNo = i;
                InspectionLine line = receipt.lines().get(i);
                futures.add(executor.submit(() -> {
                    login("concurrent-iqc-" + lineNo);
                    try {
                        start.await(10, TimeUnit.SECONDS);
                        inspectionService.dispose(
                                receipt.type(), receipt.id(), line.inspectionItemId(),
                                disposition("PASS", null,
                                        "concurrent-pass-000" + lineNo));
                        return null;
                    } finally {
                        SecurityContextHolder.clearContext();
                    }
                }));
            }
            start.countDown();
            for (Future<?> future : futures) {
                future.get(20, TimeUnit.SECONDS);
            }
        } finally {
            executor.shutdownNow();
        }

        assertThat(receiptEventCount(receipt, "RECEIPT_RESOLVED")).isEqualTo(1L);
        assertThat(receiptEventCount(receipt, "PRODUCTION_WOKEN")).isZero();
        for (InspectionLine line : receipt.lines()) {
            assertInspection(line.inspectionItemId(), "RESOLVED", "10", "0");
            assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "0");
        }

        loginCurrentEmployee("concurrent-quality-stock-in");
        int position = 0;
        for (InspectionLine line : receipt.lines()) {
            position++;
            UUID passEventId = passEventId(line.inspectionItemId());
            stockInService.confirm(
                    receipt.type(), receipt.id(),
                    stockInRequest(passEventId, "10", "10",
                            "concurrent-quality-stock-000" + position,
                            "C0" + position + "-01"));
            assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "10");
        }
    }

    @Test
    void concurrentWarehouseCommandsCannotOverstockOnePassSlice() throws Exception {
        ReceiptFixture receipt = seedReceipt(
                ProcurementInspectionPort.PURCHASE, 1, "10", "100");
        InspectionLine line = receipt.lines().getFirst();
        login("concurrent-stock-in-quality");
        inspectionService.dispose(
                receipt.type(), receipt.id(), line.inspectionItemId(),
                disposition("PASS", null, "concurrent-stock-in-pass-0001"));
        UUID passEventId = passEventId(line.inspectionItemId());
        AuthUser firstActor = createWarehouseActor("concurrent-stock-in-a");
        AuthUser secondActor = createWarehouseActor("concurrent-stock-in-b");
        CountDownLatch start = new CountDownLatch(1);
        ExecutorService executor = Executors.newFixedThreadPool(2);
        List<Future<Object>> futures = new ArrayList<>();
        try {
            List<AuthUser> actors = List.of(firstActor, secondActor);
            for (int index = 0; index < actors.size(); index++) {
                int commandNo = index;
                AuthUser actor = actors.get(index);
                futures.add(executor.submit(() -> {
                    authenticate(actor);
                    try {
                        start.await(10, TimeUnit.SECONDS);
                        return stockInService.confirm(
                                receipt.type(), receipt.id(),
                                stockInRequest(passEventId, "10", "10",
                                        "concurrent-stock-command-000" + commandNo,
                                        "CC-01"));
                    } catch (RuntimeException error) {
                        return error;
                    } finally {
                        SecurityContextHolder.clearContext();
                    }
                }));
            }
            start.countDown();
            List<Object> results = new ArrayList<>();
            for (Future<Object> future : futures) {
                results.add(future.get(30, TimeUnit.SECONDS));
            }
            assertThat(results.stream().filter(ConfirmResult.class::isInstance).count())
                    .isEqualTo(1L);
            assertThat(results.stream().filter(ApiException.class::isInstance).count())
                    .isEqualTo(1L);
        } finally {
            executor.shutdownNow();
        }

        assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "10");
        assertQuantity(stockedProjection(line.inspectionItemId()), "10");
        assertThat(stockInItemCount(receipt.id())).isEqualTo(1L);
        assertThat(stockInBatchCount(receipt.id())).isEqualTo(1L);
        assertThat(movementCount(receipt.id())).isEqualTo(1L);
    }

    @Test
    void databaseRejectsForgedProjectionAndMutationOfStockInEvidence() {
        ReceiptFixture receipt = seedReceipt(
                ProcurementInspectionPort.PURCHASE, 1, "10", "100");
        InspectionLine line = receipt.lines().getFirst();
        login("stock-in-db-guard-quality");
        inspectionService.dispose(
                receipt.type(), receipt.id(), line.inspectionItemId(),
                disposition("PASS", null, "stock-in-db-guard-pass-0001"));

        org.assertj.core.api.Assertions.assertThatThrownBy(() -> jdbc.update("""
                        UPDATE procurement_inspection_items
                        SET warehouse_stocked_base_qty = 1
                        WHERE id = ?
                        """, line.inspectionItemId()))
                .isInstanceOf(RuntimeException.class);
        assertQuantity(stockedProjection(line.inspectionItemId()), "0");

        loginCurrentEmployee("stock-in-db-guard-warehouse");
        UUID passEventId = passEventId(line.inspectionItemId());
        stockInService.confirm(
                receipt.type(), receipt.id(),
                stockInRequest(passEventId, "4", "10",
                        "stock-in-db-guard-command-0001", "D01-01"));
        Map<String, Object> evidence = jdbc.queryForMap("""
                SELECT item.id AS item_id, item.stock_movement_id
                FROM procurement_iqc_stock_in_batch_items item
                JOIN procurement_iqc_stock_in_batches batch ON batch.id = item.batch_id
                WHERE batch.receipt_id = ?
                """, receipt.id());

        org.assertj.core.api.Assertions.assertThatThrownBy(() -> jdbc.update(
                        "UPDATE procurement_iqc_stock_in_batch_items SET base_qty=3 WHERE id=?",
                        evidence.get("item_id")))
                .isInstanceOf(RuntimeException.class);
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> jdbc.update(
                        "DELETE FROM stock_movements WHERE id=?",
                        evidence.get("stock_movement_id")))
                .isInstanceOf(RuntimeException.class);
        assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "4");
        assertQuantity(stockedProjection(line.inspectionItemId()), "4");
    }

    @Test
    void databaseRejectsAForgedPassReleaseValuationAtCommit() {
        ReceiptFixture receipt = seedReceipt(
                ProcurementInspectionPort.PURCHASE, 1, "10", "100");
        InspectionLine line = receipt.lines().getFirst();
        AuthUser actor = createWarehouseActor("forged-pass-release");
        authenticate(actor);
        UUID forgedEventId = UUID.randomUUID();

        org.assertj.core.api.Assertions.assertThatThrownBy(() ->
                transactions.executeWithoutResult(ignored -> {
                    jdbc.update("""
                            UPDATE procurement_inspection_items
                            SET passed_base_qty=1,status='PARTIAL',updated_at=now()
                            WHERE id=?
                            """, line.inspectionItemId());
                    jdbc.update("""
                            INSERT INTO procurement_inspection_events(
                                id,inspection_item_id,action,base_qty,
                                actor_employee_id,requires_warehouse_stock_in,
                                released_amount_local,occurred_at)
                            VALUES (?,?,'PASS',1,?,TRUE,999,now())
                            """, forgedEventId, line.inspectionItemId(),
                            actor.getEmployeeId());
                }))
                .isInstanceOf(RuntimeException.class)
                .hasMessageContaining("frozen receipt quantity, amount and weight sequence");

        assertInspection(line.inspectionItemId(), "PENDING", "0", "0");
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM procurement_inspection_events WHERE id=?
                """, Long.class, forgedEventId)).isZero();
    }

    private ReceiptFixture seedReceipt(
            String type, int lineCount, String receivedQty, String receivedAmount) {
        UUID warehouseId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        String suffix = UUID.randomUUID().toString();
        LocalDate billDate = LocalDate.of(2026, 8, 14);
        jdbc.update("INSERT INTO warehouses(id,code,name) VALUES (?,?,?)",
                warehouseId, "W-IQC-" + suffix, "IQC integrity warehouse");
        String receiptTable = ProcurementInspectionPort.PURCHASE.equals(type)
                ? "purchase_receipts" : "subcontract_receipts";
        String receiptNo = businessIdentifier(
                ProcurementInspectionPort.PURCHASE.equals(type) ? "CJ" : "EJ",
                billDate);
        jdbc.update("INSERT INTO " + receiptTable
                        + "(id,bill_no,bill_date,warehouse_id,status,is_deleted) "
                        + "VALUES (?,?,?,?,1,FALSE)",
                receiptId, receiptNo, billDate, warehouseId);

        List<InspectionLine> lines = new ArrayList<>();
        for (int index = 0; index < lineCount; index++) {
            UUID goodsId = UUID.randomUUID();
            UUID receiptItemId = UUID.randomUUID();
            UUID inspectionItemId = UUID.randomUUID();
            String goodsCode = "G-IQC-" + suffix + '-' + index;
            String goodsName = "IQC integrity goods " + index;
            jdbc.update("INSERT INTO goods(id,code,name,min_qty,code_sequence) "
                            + "VALUES (?,?,?,0,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",
                    goodsId, goodsCode, goodsName);
            String itemTable = ProcurementInspectionPort.PURCHASE.equals(type)
                    ? "purchase_receipt_items" : "subcontract_receipt_items";
            jdbc.update("INSERT INTO " + itemTable + "("
                            + "id,bill_no,bill_date,receipt_id,line_no,goods_id,"
                            + "goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,"
                            + "goods_snapshot_locked_at,unit_rate,qty,amount_local,is_deleted) "
                            + "VALUES (?,?,?,?,?,?,?,?,'MASTER_AT_APPROVAL',now(),1,?,?,FALSE)",
                    receiptItemId, receiptNo, billDate, receiptId, index + 1,
                    goodsId, goodsCode, goodsName,
                    decimal(receivedQty), decimal(receivedAmount));
            jdbc.update("""
                    INSERT INTO procurement_inspection_items (
                        id, receipt_type, receipt_id, receipt_item_id,
                        warehouse_id, goods_id, unit_rate,
                        received_base_qty, received_amount_local, status)
                    VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, 'PENDING')
                    """, inspectionItemId, type, receiptId, receiptItemId,
                    warehouseId, goodsId, decimal(receivedQty),
                    decimal(receivedAmount));
            lines.add(new InspectionLine(goodsId, receiptItemId, inspectionItemId));
        }
        return new ReceiptFixture(type, receiptId, warehouseId, List.copyOf(lines));
    }

    private ProductionIqcFixture seedProductionIqcReceipt() {
        return transactions.execute(ignored ->
                seedProductionIqcReceiptInTransaction());
    }

    private ProductionIqcFixture seedProductionIqcReceiptInTransaction() {
        UUID unitId = UUID.randomUUID();
        UUID productId = UUID.randomUUID();
        UUID materialId = UUID.randomUUID();
        UUID unrelatedGoodsId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID materialBalanceId = UUID.randomUUID();
        UUID unrelatedBalanceId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        UUID segmentId = UUID.randomUUID();
        UUID demandId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        UUID orderPegId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        UUID productionReceiptItemId = UUID.randomUUID();
        UUID unrelatedReceiptItemId = UUID.randomUUID();
        UUID productionInspectionId = UUID.randomUUID();
        UUID unrelatedInspectionId = UUID.randomUUID();
        LocalDate billDate = LocalDate.of(2026, 8, 28);
        String suffix = UUID.randomUUID().toString();
        String planNo = businessIdentifier("SJ", billDate);
        String orderNo = businessIdentifier("CD", billDate);
        String receiptNo = businessIdentifier("CJ", billDate);

        jdbc.update("INSERT INTO units(id,code,name) VALUES (?,?,?)",
                unitId, "U-IQC-" + suffix, "IQC piece");
        jdbc.update("INSERT INTO warehouses(id,code,name) VALUES (?,?,?)",
                warehouseId, "W-IQC-PROD-" + suffix, "IQC production warehouse");
        for (UUID goodsId : List.of(productId, materialId, unrelatedGoodsId)) {
            jdbc.update("INSERT INTO goods(id,code,name,min_qty,code_sequence) "
                            + "VALUES (?,?,?,0,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",
                    goodsId, "G-IQC-PROD-" + goodsId, "IQC production goods");
        }
        jdbc.update("INSERT INTO stock_balances(id,warehouse_id,goods_id,qty) VALUES (?,?,?,0)",
                materialBalanceId, warehouseId, materialId);
        jdbc.update("INSERT INTO stock_balances(id,warehouse_id,goods_id,qty) VALUES (?,?,?,0)",
                unrelatedBalanceId, warehouseId, unrelatedGoodsId);
        jdbc.update("INSERT INTO production_plans(id,bill_no,bill_date,delivery_date,status) "
                        + "VALUES (?,?,?,?,1)",
                planId, planNo, billDate, billDate.plusDays(7));
        jdbc.update("""
                INSERT INTO production_plan_items(
                    id,bill_no,bill_date,plan_id,line_no,product_no,
                    goods_id,unit_id,unit_rate,qty)
                VALUES (?,?,?,?,1,?,?,?,1,4)
                """, planItemId, planNo, billDate, planId,
                "PRODUCT-" + planItemId, productId, unitId);
        jdbc.update("""
                INSERT INTO production_planning_packages(
                    id,plan_id,warehouse_id,idempotency_key,request_hash,
                    preview_fingerprint,status,execution_model_version)
                VALUES (?,?,?,?,?,?,'CONFIRMED',1)
                """, packageId, planId, warehouseId, "package-" + packageId,
                "a".repeat(64), "b".repeat(64));
        jdbc.update("""
                INSERT INTO production_execution_segments(
                    id,package_id,plan_id,source_plan_item_id,segment_no,
                    segment_code,client_segment_key,product_goods_id,
                    product_unit_id,product_unit_rate,planned_qty,status,
                    bom_fingerprint,idempotency_key,auto_promote_when_ready)
                VALUES (?,?,?,?,1,?,?,?, ?,1,4,'WAITING',?,?,TRUE)
                """, segmentId, packageId, planId, planItemId,
                canonicalSegmentCode(segmentId), "CLIENT-" + segmentId,
                productId, unitId, "c".repeat(64), "segment-" + segmentId);
        jdbc.update("""
                INSERT INTO production_material_demands(
                    id,package_id,plan_id,warehouse_id,goods_id,unit_id,
                    required_qty,need_date,supply_route,status,idempotency_key,
                    execution_segment_id,source_plan_item_id,per_product_qty)
                VALUES (?,?,?,?,?,?,4,?,'BUY','WAITING_SUPPLY',?,?,?,1)
                """, demandId, packageId, planId, warehouseId, materialId, unitId,
                billDate.plusDays(3), "demand-" + demandId, segmentId, planItemId);
        jdbc.update("INSERT INTO purchase_orders(id,bill_no,bill_date,warehouse_id,status) "
                        + "VALUES (?,?,?,?,1)",
                orderId, orderNo, billDate, warehouseId);
        jdbc.update("""
                INSERT INTO purchase_order_items(
                    id,bill_no,bill_date,order_id,goods_id,unit_id,
                    unit_rate,qty,goods_snapshot_source)
                VALUES (?,?,?,?,?,?,1,6,'MASTER_AT_SAVE')
                """, orderItemId, orderNo, billDate, orderId, materialId, unitId);
        jdbc.update("""
                INSERT INTO production_material_supply_pegs(
                    id,demand_id,supply_type,supply_item_id,allocated_qty,
                    consumed_qty,released_qty,expected_date,status,idempotency_key)
                VALUES (?,?,'PURCHASE_ORDER_ITEM',?,4,0,0,?,'EFFECTIVE',?)
                """, orderPegId, demandId, orderItemId, billDate.plusDays(2),
                "order-peg-" + orderPegId);
        jdbc.update("INSERT INTO purchase_receipts(id,bill_no,bill_date,warehouse_id,status,is_deleted) "
                        + "VALUES (?,?,?,?,1,FALSE)",
                receiptId, receiptNo, billDate, warehouseId);
        jdbc.update("""
                INSERT INTO purchase_receipt_items(
                    id,bill_no,bill_date,receipt_id,line_no,order_item_id,
                    goods_id,goods_code_snapshot,goods_name_snapshot,
                    goods_snapshot_source,goods_snapshot_locked_at,
                    unit_id,unit_rate,qty,amount_local,is_deleted)
                VALUES (?,?,?,?,1,?,?,?,?, 'MASTER_AT_APPROVAL',now(),?,1,6,60,FALSE)
                """, productionReceiptItemId, receiptNo, billDate, receiptId,
                orderItemId, materialId, "G-IQC-PROD-" + materialId,
                "IQC production material", unitId);
        jdbc.update("""
                INSERT INTO purchase_receipt_items(
                    id,bill_no,bill_date,receipt_id,line_no,goods_id,
                    goods_code_snapshot,goods_name_snapshot,
                    goods_snapshot_source,goods_snapshot_locked_at,
                    unit_id,unit_rate,qty,amount_local,is_deleted)
                VALUES (?,?,?,?,2,?,?,?, 'MASTER_AT_APPROVAL',now(),?,1,3,30,FALSE)
                """, unrelatedReceiptItemId, receiptNo, billDate, receiptId,
                unrelatedGoodsId, "G-IQC-PROD-" + unrelatedGoodsId,
                "IQC unrelated material", unitId);
        jdbc.update("""
                INSERT INTO procurement_inspection_items(
                    id,receipt_type,receipt_id,receipt_item_id,warehouse_id,
                    goods_id,unit_id,unit_rate,received_base_qty,
                    received_amount_local,status)
                VALUES (?,'PURCHASE',?,?,?,?,?,1,6,60,'PENDING')
                """, productionInspectionId, receiptId, productionReceiptItemId,
                warehouseId, materialId, unitId);
        jdbc.update("""
                INSERT INTO procurement_inspection_items(
                    id,receipt_type,receipt_id,receipt_item_id,warehouse_id,
                    goods_id,unit_id,unit_rate,received_base_qty,
                    received_amount_local,status)
                VALUES (?,'PURCHASE',?,?,?,?,?,1,3,30,'PENDING')
                """, unrelatedInspectionId, receiptId, unrelatedReceiptItemId,
                warehouseId, unrelatedGoodsId, unitId);

        ReceiptFixture receipt = new ReceiptFixture(
                ProcurementInspectionPort.PURCHASE,
                receiptId,
                warehouseId,
                List.of(
                        new InspectionLine(
                                materialId, productionReceiptItemId, productionInspectionId),
                        new InspectionLine(
                                unrelatedGoodsId, unrelatedReceiptItemId, unrelatedInspectionId)));
        return new ProductionIqcFixture(
                receipt, segmentId, demandId, orderPegId, orderId);
    }

    private void assertInspection(
            UUID inspectionItemId, String status, String passed, String failed) {
        var row = jdbc.queryForMap("""
                SELECT status, passed_base_qty, failed_base_qty
                FROM procurement_inspection_items WHERE id=?
                """, inspectionItemId);
        assertThat(row.get("status")).isEqualTo(status);
        assertQuantity(row.get("passed_base_qty"), passed);
        assertQuantity(row.get("failed_base_qty"), failed);
    }

    private ProductionStockFactCounts productionStockFactCounts() {
        return new ProductionStockFactCounts(
                jdbc.queryForObject(
                        "SELECT COUNT(*) FROM stock_reservations", Long.class),
                jdbc.queryForObject(
                        "SELECT COUNT(*) FROM production_material_receipt_allocations",
                        Long.class),
                jdbc.queryForObject(
                        "SELECT COUNT(*) FROM production_material_subcontract_receipt_allocations",
                        Long.class),
                jdbc.queryForObject("""
                        SELECT COUNT(*) FROM stock_documents
                        WHERE doc_type='DRAW' AND is_deleted=FALSE
                        """, Long.class));
    }

    private void assertProductionStockFactsUnchanged(ProductionStockFactCounts expected) {
        assertThat(productionStockFactCounts()).isEqualTo(expected);
    }

    private BigDecimal stockQty(UUID warehouseId, UUID goodsId) {
        return jdbc.queryForObject("""
                SELECT COALESCE((
                    SELECT qty FROM stock_balances
                    WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL
                ),0)
                """, BigDecimal.class, warehouseId, goodsId);
    }

    private BigDecimal stockedProjection(UUID inspectionItemId) {
        return jdbc.queryForObject("""
                SELECT warehouse_stocked_base_qty
                FROM procurement_inspection_items
                WHERE id=?
                """, BigDecimal.class, inspectionItemId);
    }

    private UUID passEventId(UUID inspectionItemId) {
        return jdbc.queryForObject("""
                SELECT id
                FROM procurement_inspection_events
                WHERE inspection_item_id=? AND action='PASS'
                ORDER BY occurred_at, id
                LIMIT 1
                """, UUID.class, inspectionItemId);
    }

    private List<UUID> passEventIds(UUID inspectionItemId) {
        return jdbc.queryForList("""
                SELECT id
                FROM procurement_inspection_events
                WHERE inspection_item_id=? AND action='PASS'
                ORDER BY occurred_at, id
                """, UUID.class, inspectionItemId);
    }

    private long stockInItemCount(UUID receiptId) {
        return jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM procurement_iqc_stock_in_batch_items item
                JOIN procurement_iqc_stock_in_batches batch ON batch.id=item.batch_id
                WHERE batch.receipt_id=?
                """, Long.class, receiptId);
    }

    private long stockInBatchCount(UUID receiptId) {
        return jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM procurement_iqc_stock_in_batches
                WHERE receipt_id=?
                """, Long.class, receiptId);
    }

    private BigDecimal movementTotal(UUID receiptId, short direction, String column) {
        if (!Set.of("qty", "amount_local").contains(column)) {
            throw new IllegalArgumentException("unsupported movement column");
        }
        return jdbc.queryForObject(
                "SELECT COALESCE(SUM(" + column + "),0) FROM stock_movements "
                        + "WHERE source_doc_id=? AND direction=?",
                BigDecimal.class, receiptId, direction);
    }

    private long movementCount(UUID receiptId) {
        return jdbc.queryForObject(
                "SELECT COUNT(*) FROM stock_movements WHERE source_doc_id=?",
                Long.class, receiptId);
    }

    private long receiptEventCount(ReceiptFixture receipt, String action) {
        return jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM procurement_inspection_events event
                JOIN procurement_inspection_items item
                  ON item.id = event.inspection_item_id
                WHERE item.receipt_type=? AND item.receipt_id=?
                  AND event.action=?
                """, Long.class, receipt.type(), receipt.id(), action);
    }

    private String segmentStatus(UUID segmentId) {
        return jdbc.queryForObject(
                "SELECT status FROM production_execution_segments WHERE id=?",
                String.class, segmentId);
    }

    private BigDecimal pegConsumed(UUID pegId) {
        return jdbc.queryForObject(
                "SELECT consumed_qty FROM production_material_supply_pegs WHERE id=?",
                BigDecimal.class, pegId);
    }

    private BigDecimal activeReceiptAllocationQty(UUID receiptId) {
        return jdbc.queryForObject("""
                SELECT COALESCE(SUM(allocated_qty),0)
                FROM production_material_receipt_allocations
                WHERE receipt_id=? AND status='EFFECTIVE'
                """, BigDecimal.class, receiptId);
    }

    private long activeReceiptAllocationCount(UUID receiptId) {
        return jdbc.queryForObject("""
                SELECT COUNT(*) FROM production_material_receipt_allocations
                WHERE receipt_id=? AND status='EFFECTIVE'
                """, Long.class, receiptId);
    }

    private long reversedReceiptAllocationCount(UUID receiptId) {
        return jdbc.queryForObject("""
                SELECT COUNT(*) FROM production_material_receipt_allocations
                WHERE receipt_id=? AND status='REVERSED'
                """, Long.class, receiptId);
    }

    private long activeProductionReservationCount(UUID demandId) {
        return jdbc.queryForObject("""
                SELECT COUNT(*) FROM stock_reservations
                WHERE demand_id=? AND is_deleted=FALSE AND status=0
                """, Long.class, demandId);
    }

    private long activeDrawCount(UUID segmentId) {
        return jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM production_planning_package_documents package_document
                JOIN stock_documents draw ON draw.id=package_document.document_id
                WHERE package_document.execution_segment_id=?
                  AND package_document.document_type='DRAW'
                  AND draw.is_deleted=FALSE AND draw.status=0
                """, Long.class, segmentId);
    }

    private static InspectionDispositionRequest disposition(
            String action, String qty, String key) {
        return new InspectionDispositionRequest(
                action, qty == null ? null : decimal(qty), "verified by IQC", key);
    }

    private static ConfirmRequest stockInRequest(
            UUID passEventId,
            String qty,
            String expectedRemaining,
            String key,
            String place) {
        return new ConfirmRequest(
                key,
                List.of(new ConfirmItem(
                        passEventId,
                        decimal(qty),
                        decimal(expectedRemaining),
                        place)));
    }

    private void login(String login) {
        authenticate(createWarehouseActor(login));
    }

    private void loginCurrentEmployee(String login) {
        authenticate(createWarehouseActor(login));
    }

    private AuthUser createWarehouseActor(String login) {
        UUID employeeId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        UUID departmentId = jdbc.queryForObject("""
                SELECT id FROM departments
                WHERE code='SUB_WH' AND is_deleted=FALSE
                """, UUID.class);
        jdbc.update("""
                INSERT INTO employees(
                    id,code,full_name,id_type,department_id,hire_date,
                    status,employment_type)
                VALUES (?,?,?,'其他',?,?,'active','regular')
                """, employeeId, "E-IQC-" + employeeId,
                "IQC production actor", departmentId,
                LocalDate.of(2026, 8, 28));
        jdbc.update("""
                INSERT INTO users(
                    id,employee_id,login_account,password_hash,
                    must_change_password,is_super_admin,status)
                VALUES (?,?,?,'x',FALSE,FALSE,'active')
                """, userId, employeeId, login + '-' + userId);
        return new AuthUser(
                userId, employeeId, login,
                Set.of(), Set.of(
                        "procurement_inspection:view",
                        "procurement_inspection:handle",
                        "warehouse_iqc_stock_in:view",
                        "warehouse_iqc_stock_in:confirm"),
                false, true, true);
    }

    private static void authenticate(AuthUser user) {
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(
                        user, null, user.getAuthorities()));
    }

    private static void assertQuantity(Object actual, String expected) {
        assertThat(actual).isInstanceOf(BigDecimal.class);
        assertThat(((BigDecimal) actual).compareTo(decimal(expected))).isZero();
    }

    private static String businessIdentifier(String prefix, LocalDate date) {
        int sequence = BUSINESS_IDENTIFIER_SEQUENCE.incrementAndGet();
        if (sequence > 999_999) {
            throw new IllegalStateException("test business identifier sequence exhausted");
        }
        return prefix + date.toString().replace("-", "") + "%06d".formatted(sequence);
    }

    private static BigDecimal decimal(String value) {
        return new BigDecimal(value);
    }

    private static String canonicalSegmentCode(UUID segmentId) {
        return "ZX%08d".formatted(
                Math.floorMod(segmentId.hashCode(), 99_999_999) + 1);
    }

    private record ReceiptFixture(
            String type, UUID id, UUID warehouseId, List<InspectionLine> lines) {
    }

    private record InspectionLine(
            UUID goodsId, UUID receiptItemId, UUID inspectionItemId) {
    }

    private record ProductionIqcFixture(
            ReceiptFixture receipt,
            UUID segmentId,
            UUID demandId,
            UUID orderPegId,
            UUID orderId) {
    }

    private record ProductionStockFactCounts(
            long reservations,
            long purchaseReceiptAllocations,
            long subcontractReceiptAllocations,
            long draws) {
    }
}
