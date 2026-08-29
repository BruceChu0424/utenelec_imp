package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.ProcurementInspectionPort;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
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
    @Autowired private ProductionSupplyTransitionPort productionSupply;
    @Autowired private TxSessionVars tx;

    @AfterEach
    void clearSecurity() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void partialPassAndFailOnlyStockTheQualifiedQuantityAndReverseExactly() {
        ReceiptFixture receipt = seedReceipt(
                ProcurementInspectionPort.PURCHASE, 1, "10", "100");
        InspectionLine line = receipt.lines().getFirst();
        login("partial-pass-fail");

        inspectionService.dispose(receipt.type(), receipt.id(), line.inspectionItemId(),
                disposition("PASS", "6", "partial-pass-0001"));
        assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "6");
        assertThat(receiptEventCount(receipt, "PRODUCTION_WOKEN")).isZero();

        inspectionService.dispose(receipt.type(), receipt.id(), line.inspectionItemId(),
                disposition("FAIL", "4", "partial-fail-0001"));
        assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "6");
        assertThat(receiptEventCount(receipt, "PRODUCTION_WOKEN")).isEqualTo(1L);
        assertInspection(line.inspectionItemId(), "RESOLVED", "6", "4");
        assertNoProductionStockFacts();

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
    void partialPassAdvancesFormalSupplyWhileAnotherReceiptLineRemainsPending()
            throws Exception {
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
        assertThat(segmentStatus(fixture.segmentId())).isEqualTo("READY");
        assertQuantity(pegConsumed(fixture.orderPegId()), "4");
        assertQuantity(activeReceiptAllocationQty(receipt.id()), "4");
        assertThat(activeReceiptAllocationCount(receipt.id())).isEqualTo(1L);
        assertThat(activeProductionReservationCount(fixture.demandId())).isEqualTo(1L);
        assertThat(activeDrawCount(fixture.segmentId())).isEqualTo(1L);
        assertThat(receiptEventCount(receipt, "PRODUCTION_WOKEN")).isZero();

        // Same event replay re-enters the formal transition, but the cumulative
        // qualified quantity is already fully represented by one allocation.
        inspectionService.dispose(
                receipt.type(), receipt.id(), productionLine.inspectionItemId(), firstPass);
        assertQuantity(activeReceiptAllocationQty(receipt.id()), "4");
        assertThat(activeReceiptAllocationCount(receipt.id())).isEqualTo(1L);
        assertThat(activeProductionReservationCount(fixture.demandId())).isEqualTo(1L);
        assertThat(activeDrawCount(fixture.segmentId())).isEqualTo(1L);

        // Later decisions close each inspection line without changing the first
        // qualified slice or duplicating its reservation/DRAW provenance.
        inspectionService.dispose(
                receipt.type(), receipt.id(), productionLine.inspectionItemId(),
                disposition("FAIL", "2", "formal-fail-0001"));
        assertInspection(productionLine.inspectionItemId(), "RESOLVED", "4", "2");
        assertThat(receiptEventCount(receipt, "PRODUCTION_WOKEN")).isZero();

        inspectionService.dispose(
                receipt.type(), receipt.id(), unrelatedLine.inspectionItemId(),
                disposition("PASS", null, "unrelated-pass-0001"));
        assertInspection(unrelatedLine.inspectionItemId(), "RESOLVED", "3", "0");
        assertThat(receiptEventCount(receipt, "PRODUCTION_WOKEN")).isEqualTo(1L);
        assertQuantity(activeReceiptAllocationQty(receipt.id()), "4");
        assertThat(activeReceiptAllocationCount(receipt.id())).isEqualTo(1L);

        transactions.executeWithoutResult(ignored -> {
            tx.bind();
            productionSupply.lockPurchaseReceiptMutationDimensions(receipt.id());
            inspectionService.requireResolvedForReverse(receipt.type(), receipt.id());
            productionSupply.beforePurchaseReceiptReversed(receipt.id());
            inspectionService.reverseResolvedStock(
                    receipt.type(), receipt.id(), OffsetDateTime.now());
            jdbc.update("UPDATE purchase_receipts SET status=-1 WHERE id=?", receipt.id());
            productionSupply.afterPurchaseReceiptReversed(receipt.id());
        });

        assertThat(segmentStatus(fixture.segmentId())).isEqualTo("WAITING");
        assertQuantity(pegConsumed(fixture.orderPegId()), "0");
        assertThat(activeReceiptAllocationCount(receipt.id())).isZero();
        assertThat(reversedReceiptAllocationCount(receipt.id())).isEqualTo(1L);
        assertThat(activeProductionReservationCount(fixture.demandId())).isZero();
        assertThat(activeDrawCount(fixture.segmentId())).isZero();
        assertQuantity(stockQty(receipt.warehouseId(), productionLine.goodsId()), "0");
        assertQuantity(stockQty(receipt.warehouseId(), unrelatedLine.goodsId()), "0");
        assertInspection(productionLine.inspectionItemId(), "REVERSED", "0", "0");
        assertInspection(unrelatedLine.inspectionItemId(), "REVERSED", "0", "0");
        assertQuantity(movementTotal(receipt.id(), (short) 1, "qty"), "7");
        assertQuantity(movementTotal(receipt.id(), (short) -1, "qty"), "7");
    }

    @Test
    void fullSubcontractFailClosesAndRefreshesWithoutUsableOrReservedStock() {
        ReceiptFixture receipt = seedReceipt(
                ProcurementInspectionPort.SUBCONTRACT, 1, "10", "100");
        InspectionLine line = receipt.lines().getFirst();
        login("full-subcontract-fail");

        inspectionService.dispose(receipt.type(), receipt.id(), line.inspectionItemId(),
                disposition("FAIL", null, "full-fail-0001"));

        assertInspection(line.inspectionItemId(), "RESOLVED", "0", "10");
        assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "0");
        assertThat(movementCount(receipt.id())).isZero();
        assertThat(receiptEventCount(receipt, "PRODUCTION_WOKEN")).isEqualTo(1L);
        assertNoProductionStockFacts();
    }

    @Test
    void concurrentLastLinesSerializeToOneWholeReceiptWake() throws Exception {
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

        assertThat(receiptEventCount(receipt, "PRODUCTION_WOKEN")).isEqualTo(1L);
        for (InspectionLine line : receipt.lines()) {
            assertInspection(line.inspectionItemId(), "RESOLVED", "10", "0");
            assertQuantity(stockQty(receipt.warehouseId(), line.goodsId()), "10");
        }
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
        return new ProductionIqcFixture(receipt, segmentId, demandId, orderPegId);
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

    private void assertNoProductionStockFacts() {
        assertThat(jdbc.queryForObject(
                "SELECT COUNT(*) FROM stock_reservations", Long.class)).isZero();
        assertThat(jdbc.queryForObject(
                "SELECT COUNT(*) FROM production_material_receipt_allocations",
                Long.class)).isZero();
        assertThat(jdbc.queryForObject(
                "SELECT COUNT(*) FROM production_material_subcontract_receipt_allocations",
                Long.class)).isZero();
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM stock_documents
                WHERE doc_type='DRAW' AND is_deleted=FALSE
                """, Long.class)).isZero();
    }

    private BigDecimal stockQty(UUID warehouseId, UUID goodsId) {
        return jdbc.queryForObject("""
                SELECT COALESCE((
                    SELECT qty FROM stock_balances
                    WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL
                ),0)
                """, BigDecimal.class, warehouseId, goodsId);
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

    private static void login(String login) {
        AuthUser user = new AuthUser(
                UUID.randomUUID(), UUID.randomUUID(), login,
                Set.of(), Set.of(
                        "procurement_inspection:view",
                        "procurement_inspection:handle"),
                false, true, true);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(
                        user, null, user.getAuthorities()));
    }

    private void loginCurrentEmployee(String login) {
        UUID employeeId = UUID.randomUUID();
        UUID departmentId = jdbc.queryForObject("""
                SELECT id FROM departments
                WHERE is_deleted=FALSE
                ORDER BY code, id
                LIMIT 1
                """, UUID.class);
        jdbc.update("""
                INSERT INTO employees(
                    id,code,full_name,id_type,department_id,hire_date,
                    status,employment_type)
                VALUES (?,?,?,'其他',?,?,'active','regular')
                """, employeeId, "E-IQC-" + employeeId,
                "IQC production actor", departmentId,
                LocalDate.of(2026, 8, 28));
        AuthUser user = new AuthUser(
                UUID.randomUUID(), employeeId, login,
                Set.of(), Set.of(
                        "procurement_inspection:view",
                        "procurement_inspection:handle"),
                false, true, true);
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
            UUID orderPegId) {
    }
}
