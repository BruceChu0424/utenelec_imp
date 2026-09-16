package com.uten.imp.features.purchase.common;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V593 采购/委外「主档默认值」写回真库锁。首版 V592 客户条款写回曾漏 DB 触发器
 * 契约整单打回——本用例在没有触发器知识的前提下必然红：
 * <ul>
 *   <li>suppliers 结账方式必须过 fn_sync_supplier_default_settlement_method_reference()
 *       （V452，与客户 V285 同款）：UUID 与 price_style 成对一致、只认「使用中」字典；</li>
 *   <li>货品默认供应商/两价写回；空项保值、值没变不落盘（xmin 探针）。</li>
 * </ul>
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
                "uten.jwt.secret=proc-defaults-harness-jwt-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=proc-defaults-harness-pgp-key-test-only-0123",
                "uten.crypto.hmac-key=proc-defaults-harness-hmac-key-test-only",
                "uten.bootstrap.admin-login=proc-defaults-bootstrap-admin-test",
                "uten.bootstrap.admin-password=ProcDefaultsAdminPass-1!"
        })
class ProcurementMasterDefaultsSyncPostgresTest {

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

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private ProcurementMasterDefaultsSyncService sync;

    /** 单据号序号（触发器校验注册格式 XD/PO/SC+日期+6 位）。 */
    private static final java.util.concurrent.atomic.AtomicInteger billSeq =
            new java.util.concurrent.atomic.AtomicInteger(900001);

    /** 测试字典 legacy_id 序号（确定性，避免弱随机）。 */
    private static final java.util.concurrent.atomic.AtomicInteger legacySeq =
            new java.util.concurrent.atomic.AtomicInteger(9100);

    @Autowired
    private PlatformTransactionManager txm;

    @BeforeEach
    void clean() {
        jdbc.update("DELETE FROM purchase_order_items");
        jdbc.update("DELETE FROM purchase_orders");
        jdbc.update("DELETE FROM subcontract_order_items");
        jdbc.update("DELETE FROM subcontract_orders");
        jdbc.update("DELETE FROM goods WHERE code LIKE 'G-SYNC-%'");
        jdbc.update("DELETE FROM suppliers WHERE code LIKE 'SUP-SYNC-%'");
        jdbc.update("DELETE FROM settlement_methods WHERE code LIKE 'STM-SYNC-%'");
        jdbc.update("DELETE FROM currencies WHERE code LIKE 'CUR-SYNC-%'");
    }

    @Test
    void purchaseOrderLearnsGoodsSupplierPriceAndSupplierTermsThroughTheTrigger() {
        UUID supplier = supplier("SUP-SYNC-A");
        UUID goods = goods("G-SYNC-1");
        UUID settlementActive = settlement("STM-SYNC-ON");
        UUID settlementDisabled = settlement("STM-SYNC-OFF", "禁用");
        UUID currency = currency("CUR-SYNC-CNY");
        UUID order = purchaseOrder(supplier, goods, settlementActive, currency, "13.0000");

        // ① 保存写回：货品绑定供应商+采购单价；供应商条款成对过触发器。
        inTx(() -> sync.syncFromPurchaseOrder(order));
        assertThat(goodsSupplier(goods)).isEqualTo(supplier);
        assertThat(goodsPurchasePrice(goods)).isEqualByComparingTo("12.500000");
        assertThat(supplierSettlement(supplier)).isEqualTo(settlementActive);
        assertThat(supplierCurrency(supplier)).isEqualTo(currency);
        assertThat(supplierTaxRate(supplier)).isEqualByComparingTo("13.0000");
        Integer shadow = settlementLegacy(settlementActive);
        assertThat(supplierShadow(supplier)).isEqualTo(shadow);

        // ② 供应商行已有另一套非空 price_style（与单头字典不同）——触发器冲突场景，
        //    成对写必须存活（V592 客户侧事故同款回归）。
        UUID other = settlement("STM-SYNC-OTHER");
        jdbc.update("UPDATE suppliers SET default_settlement_method_id = ?, price_style = ? WHERE id = ?",
                other, settlementLegacy(other), supplier);
        UUID order2 = purchaseOrder(supplier, goods, settlementActive, currency, "13.0000");
        inTx(() -> sync.syncFromPurchaseOrder(order2));
        assertThat(supplierSettlement(supplier)).isEqualTo(settlementActive);
        assertThat(supplierShadow(supplier)).isEqualTo(settlementLegacy(settlementActive));

        // ③ 空条款保值：单头结账方式/币种/税率为空的订单不覆盖供应商默认
        //（停用字典场景由 ClientDefaultTermsSyncPostgresTest 同款锁覆盖——订单表
        // 侧触发器直接拒绝停用字典落库，写回服务永远见不到这种行）。
        UUID order3 = purchaseOrder(supplier, goods, null, null, null);
        inTx(() -> sync.syncFromPurchaseOrder(order3));
        assertThat(supplierSettlement(supplier)).isEqualTo(settlementActive);
        assertThat(supplierCurrency(supplier)).isEqualTo(currency);
        assertThat(supplierTaxRate(supplier)).isEqualByComparingTo("13.0000");

        // ④ 值没变不落盘（货品行 xmin 不变）。
        String xmin = goodsXmin(goods);
        inTx(() -> sync.syncFromPurchaseOrder(order2));
        assertThat(goodsXmin(goods)).isEqualTo(xmin);
    }

    @Test
    void subcontractOrderLearnsGoodsSubcontractPriceAndSupplierTerms() {
        UUID supplier = supplier("SUP-SYNC-B");
        UUID goods = goods("G-SYNC-2");
        UUID settlement = settlement("STM-SYNC-SC");
        UUID currency = currency("CUR-SYNC-USD");
        UUID order = subcontractOrder(supplier, goods, settlement, currency, "6.5000");

        inTx(() -> sync.syncFromSubcontractOrder(order));
        assertThat(goodsSupplier(goods)).isEqualTo(supplier);
        assertThat(goodsSubcontractPrice(goods)).isEqualByComparingTo("45.000000");
        assertThat(supplierSettlement(supplier)).isEqualTo(settlement);
        assertThat(supplierCurrency(supplier)).isEqualTo(currency);
        assertThat(supplierTaxRate(supplier)).isEqualByComparingTo("6.5000");
        // 采购单价不被委外单动（两价分列学习）。
        assertThat(goodsPurchasePrice(goods)).isNull();
    }

    // ======================= 夹具 =======================

    private void inTx(Runnable body) {
        new TransactionTemplate(txm).executeWithoutResult(tx -> body.run());
    }

    private UUID supplier(String code) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO suppliers (id, code, name, status, code_sequence)
                VALUES (?, ?, '写回学习测试供应商', '使用',
                        (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM suppliers))
                """, id, code);
        return id;
    }

    private UUID goods(String code) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO goods (id, code, name, status, code_sequence)
                VALUES (?, ?, '写回学习测试货品', '使用',
                        (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))
                """, id, code);
        return id;
    }

    private UUID settlement(String code) {
        return settlement(code, "使用");
    }

    private UUID settlement(String code, String status) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO settlement_methods (id, code, name, status, legacy_id)
                VALUES (?, ?, '写回学习测试结算方式', ?, ?)
                """, id, code, status, legacySeq.incrementAndGet());
        return id;
    }

    private Integer settlementLegacy(UUID id) {
        Integer legacy = jdbc.queryForObject(
                "SELECT legacy_id FROM settlement_methods WHERE id = ?", Integer.class, id);
        // 触发器 canonical 为 0/NULL 时价格影子也写 0/NULL——测试字典 legacy 恒非空即可。
        return legacy == null ? 0 : legacy;
    }

    private UUID currency(String code) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO currencies (id, code, name, exchange_rate, status)
                VALUES (?, ?, '写回学习测试币种', 1.000000, '使用')
                """, id, code);
        return id;
    }

    /** 采购单 + 一行货品（价 12.50），头条款按参数。 */
    private UUID purchaseOrder(UUID supplierId, UUID goodsId, UUID settlementId, UUID currencyId, String taxRate) {
        UUID orderId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO purchase_orders (
                    id, bill_no, bill_date, supplier_id, status,
                    settlement_method_id, currency_id, tax_rate, created_at, updated_at, is_deleted)
                VALUES (?, ?, ?, ?, 0, ?, ?, ?::numeric, now(), now(), false)
                """, orderId, "CD" + "20260915" + String.format("%06d", billSeq.incrementAndGet()),
                LocalDate.of(2026, 9, 15), supplierId, settlementId, currencyId, taxRate);
        jdbc.update("""
                INSERT INTO purchase_order_items (
                    id, order_id, goods_id, qty, price, is_deleted,
                    bill_no, bill_date, goods_snapshot_source)
                VALUES (?, ?, ?, 10, 12.500000, false,
                        ?, DATE '2026-09-15', 'MASTER_AT_SAVE')
                """, UUID.randomUUID(), orderId, goodsId,
                "POI-SYNC-" + orderId.toString().substring(0, 8));
        return orderId;
    }

    private UUID subcontractOrder(UUID supplierId, UUID goodsId, UUID settlementId, UUID currencyId, String taxRate) {
        UUID orderId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO subcontract_orders (
                    id, bill_no, bill_date, supplier_id, status,
                    settlement_method_id, currency_id, tax_rate, created_at, updated_at, is_deleted)
                VALUES (?, ?, ?, ?, 0, ?, ?, ?::numeric, now(), now(), false)
                """, orderId, "EO" + "20260915" + String.format("%06d", billSeq.incrementAndGet()),
                LocalDate.of(2026, 9, 15), supplierId, settlementId, currencyId, taxRate);
        jdbc.update("""
                INSERT INTO subcontract_order_items (
                    id, order_id, goods_id, qty, price, is_deleted,
                    bill_no, bill_date, goods_snapshot_source)
                VALUES (?, ?, ?, 8, 45.000000, false,
                        ?, DATE '2026-09-15', 'MASTER_AT_SAVE')
                """, UUID.randomUUID(), orderId, goodsId,
                "SCI-SYNC-" + orderId.toString().substring(0, 8));
        return orderId;
    }

    // ======================= 断言读数 =======================

    private UUID goodsSupplier(UUID goodsId) {
        return jdbc.queryForObject(
                "SELECT default_supplier_id FROM goods WHERE id = ?", UUID.class, goodsId);
    }

    private BigDecimal goodsPurchasePrice(UUID goodsId) {
        return jdbc.queryForObject(
                "SELECT default_purchase_price FROM goods WHERE id = ?", BigDecimal.class, goodsId);
    }

    private BigDecimal goodsSubcontractPrice(UUID goodsId) {
        return jdbc.queryForObject(
                "SELECT default_subcontract_price FROM goods WHERE id = ?", BigDecimal.class, goodsId);
    }

    private String goodsXmin(UUID goodsId) {
        return jdbc.queryForObject(
                "SELECT xmin::text FROM goods WHERE id = ?", String.class, goodsId);
    }

    private UUID supplierSettlement(UUID supplierId) {
        return jdbc.queryForObject(
                "SELECT default_settlement_method_id FROM suppliers WHERE id = ?",
                UUID.class, supplierId);
    }

    private Integer supplierShadow(UUID supplierId) {
        return jdbc.queryForObject(
                "SELECT price_style FROM suppliers WHERE id = ?", Integer.class, supplierId);
    }

    private UUID supplierCurrency(UUID supplierId) {
        return jdbc.queryForObject(
                "SELECT default_currency_id FROM suppliers WHERE id = ?", UUID.class, supplierId);
    }

    private BigDecimal supplierTaxRate(UUID supplierId) {
        return jdbc.queryForObject(
                "SELECT default_tax_rate FROM suppliers WHERE id = ?", BigDecimal.class, supplierId);
    }
}
