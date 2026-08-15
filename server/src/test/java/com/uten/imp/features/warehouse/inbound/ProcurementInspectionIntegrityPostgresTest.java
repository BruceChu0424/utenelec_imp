package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.ProcurementInspectionPort;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
import com.uten.imp.security.AuthUser;
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
 * Real PostgreSQL/service proof for deterministic whole-receipt IQC closure.
 * FAIL quantities remain quality evidence only: they never enter stock or any
 * production reservation, receipt allocation or DRAW.
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

    private record ReceiptFixture(
            String type, UUID id, UUID warehouseId, List<InspectionLine> lines) {
    }

    private record InspectionLine(
            UUID goodsId, UUID receiptItemId, UUID inspectionItemId) {
    }
}
