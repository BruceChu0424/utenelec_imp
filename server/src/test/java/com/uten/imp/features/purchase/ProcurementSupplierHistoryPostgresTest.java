package com.uten.imp.features.purchase;

import com.uten.imp.features.purchase.common.ProcurementMasterDefaultsSyncService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
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
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Real PostgreSQL proof for the goods/supplier master-default prefill
 * (V593 单一事实源: 保存订货单写回主档 -> 新建单一律读主档预填)。
 *
 * <p>两件事各一条用例: ① 「按最近一张订单实时推导」的回退路径已退役 (2026-09-16),
 * 库里有订单但主档没绑定就不预填; ② 写回之后的读口径 —— 停用供应商照给条款,
 * 内部车间供应商与已删供应商不给 (条款随之为空), 行价仍由货品主档给出。
 *
 * <p>类名与端点路径 /last-terms 一样是历史遗留, 语义自 V593 起是主档默认值。
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
                "uten.jwt.secret=supplier-history-harness-jwt-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=supplier-history-harness-pgp-key-test-only-0123456",
                "uten.crypto.hmac-key=supplier-history-harness-hmac-key-test-only",
                "uten.bootstrap.admin-login=supplier-history-bootstrap-admin-test",
                "uten.bootstrap.admin-password=SupplierHistoryAdminPass-1!"
        })
class ProcurementSupplierHistoryPostgresTest {

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
    private PurchaseOrderService purchaseOrders;

    @Autowired
    private SubcontractOrderService subcontractOrders;

    @Autowired
    private ProcurementMasterDefaultsSyncService masterDefaultsSync;

    @Autowired
    private PlatformTransactionManager txm;

    /** 类级共享：同一容器库内多测试方法的供应商编码不重复（code 唯一键+保留号段触发器）。 */
    private static int supplierCodeSequence = 990000;

    /** 写回服务是 MANDATORY 传播 (挂单据事务), 测试里手动包一层事务。 */
    private void inTransaction(Runnable action) {
        new TransactionTemplate(txm).executeWithoutResult(tx -> action.run());
    }

    private static final OffsetDateTime BASE =
            OffsetDateTime.of(2026, 9, 3, 8, 0, 0, 0, ZoneOffset.UTC);

    /** 主档没绑定就不预填: 订单躺在库里也不再被实时推导出来 (回退路径已退役)。 */
    @Test
    void masterDefaultsStayEmptyUntilAnOrderSaveWritesThemBack() {
        UUID supplierCategory = supplierCategory();
        UUID goods = goods("TRM-MASTER");
        UUID supplier = supplier(supplierCategory, "使用", false, false, "master-active");
        UUID settlement = settlement("MD");
        UUID currency = currency("MD", new BigDecimal("7.250000"));

        UUID order = purchase(
                goods, supplier, settlement, currency, new BigDecimal("13.0000"),
                new BigDecimal("12.5000"), false, BASE.plusMinutes(1), 31);
        assertThat(purchaseOrders.masterDefaultTermsPerGoods(List.of(goods))).isEmpty();

        inTransaction(() -> masterDefaultsSync.syncFromPurchaseOrder(order));

        var terms = purchaseOrders.masterDefaultTermsPerGoods(List.of(goods));
        assertThat(terms).containsOnlyKeys(goods);
        var row = terms.get(goods);
        assertThat(row.supplierId()).isEqualTo(supplier);
        assertThat(row.settlementMethodId()).isEqualTo(settlement);
        assertThat(row.currencyId()).isEqualTo(currency);
        assertThat(row.exchangeRate()).isEqualByComparingTo("7.25");
        assertThat(row.taxRate()).isEqualByComparingTo("13");
        assertThat(row.purchasePrice()).isEqualByComparingTo("12.5");
    }

    /** 写回后的读口径: 停用供应商照给, 内部车间/已删供应商连同条款一起藏掉。 */
    @Test
    void masterDefaultsKeepDisabledSupplierButHideInternalAndDeletedOnes() {
        UUID supplierCategory = supplierCategory();
        UUID goods = goods("TRM-HIST");
        UUID settlement = settlement("HIST");
        UUID currency = currency("HIST", new BigDecimal("1.000000"));

        UUID disabled = supplier(supplierCategory, "禁用", false, false, "terms-disabled");
        UUID internal = supplier(supplierCategory, "使用", true, false, "terms-internal");
        UUID deletedSupplier = supplier(supplierCategory, "使用", false, true, "terms-deleted");

        // ① 停用供应商: 条款照给, 是否可回填由前端按字典判断。
        writeBackPurchase(goods, disabled, settlement, currency, BASE.plusMinutes(1), 41);
        var afterDisabled = purchaseDefaults(goods);
        assertThat(afterDisabled.supplierId()).isEqualTo(disabled);
        assertThat(afterDisabled.settlementMethodId()).isEqualTo(settlement);
        assertThat(afterDisabled.currencyId()).isEqualTo(currency);

        // ② 内部车间供应商: 主档仍绑着它, 但预填不给供应商与条款, 只留货品行价。
        writeBackPurchase(goods, internal, settlement, currency, BASE.plusMinutes(2), 42);
        var afterInternal = purchaseDefaults(goods);
        assertThat(afterInternal.supplierId()).isNull();
        assertThat(afterInternal.settlementMethodId()).isNull();
        assertThat(afterInternal.currencyId()).isNull();
        assertThat(afterInternal.taxRate()).isNull();
        assertThat(afterInternal.purchasePrice()).isNotNull();

        // ③ 已软删供应商: 同样不给。
        writeBackPurchase(goods, deletedSupplier, settlement, currency, BASE.plusMinutes(3), 43);
        assertThat(purchaseDefaults(goods).supplierId()).isNull();
    }

    /** 委外侧走自己的单价列, 不串到采购单价上。 */
    @Test
    void subcontractMasterDefaultsUseTheSubcontractPriceColumn() {
        UUID supplierCategory = supplierCategory();
        UUID goods = goods("TRM-SUB");
        UUID supplier = supplier(supplierCategory, "使用", false, false, "sub-active");
        UUID settlement = settlement("SUB");
        UUID currency = currency("SUB", new BigDecimal("1.000000"));

        UUID order = subcontract(
                goods, supplier, settlement, currency, new BigDecimal("6.0000"),
                new BigDecimal("9.7500"), false, BASE.plusMinutes(1), 51);
        assertThat(subcontractOrders.masterDefaultTermsPerGoods(List.of(goods))).isEmpty();

        inTransaction(() -> masterDefaultsSync.syncFromSubcontractOrder(order));

        var row = subcontractOrders.masterDefaultTermsPerGoods(List.of(goods)).get(goods);
        assertThat(row).isNotNull();
        assertThat(row.supplierId()).isEqualTo(supplier);
        assertThat(row.taxRate()).isEqualByComparingTo("6");
        assertThat(row.subcontractPrice()).isEqualByComparingTo("9.75");
        // 委外写回不碰采购单价列: 采购侧因默认供应商已绑定而有行, 但行价仍为空。
        assertThat(purchaseDefaults(goods).purchasePrice()).isNull();
    }

    private PurchaseOrderService.MasterDefaultTermsPerGoods purchaseDefaults(UUID goods) {
        var row = purchaseOrders.masterDefaultTermsPerGoods(List.of(goods)).get(goods);
        assertThat(row).isNotNull();
        return row;
    }

    /** 建一张采购单并按新口径写回主档 (等价于 Service.create 里 flush 之后那一步)。 */
    private void writeBackPurchase(
            UUID goods,
            UUID supplier,
            UUID settlement,
            UUID currency,
            OffsetDateTime createdAt,
            int sequence) {
        UUID order = purchase(
                goods, supplier, settlement, currency, new BigDecimal("3.0000"),
                new BigDecimal("1.5000"), false, createdAt, sequence);
        inTransaction(() -> masterDefaultsSync.syncFromPurchaseOrder(order));
    }

    private UUID supplierCategory() {
        return jdbc.queryForObject(
                "SELECT id FROM supplier_categories WHERE is_deleted=false ORDER BY id LIMIT 1",
                UUID.class);
    }

    private UUID goods(String codePrefix) {
        UUID materialCategory = jdbc.queryForObject(
                "SELECT id FROM material_categories WHERE is_deleted=false ORDER BY id LIMIT 1",
                UUID.class);
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO goods(id,category_id,code,name,status,code_sequence)
                VALUES (?,?,?,?,'使用',(SELECT COALESCE(max(code_sequence),0)+1 FROM goods))
                """, id, materialCategory, codePrefix + "-" + shortId(id), "Master default goods");
        return id;
    }

    private UUID settlement(String suffix) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO settlement_methods (id, code, name, status)
                VALUES (?, ?, '采购主档默认值测试结算方式', '使用')
                """, id, "STM-PROC-" + suffix + "-" + id.toString().substring(0, 8));
        return id;
    }

    private UUID currency(String suffix, BigDecimal rate) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO currencies (id, code, name, exchange_rate, status)
                VALUES (?, ?, '采购主档默认值测试币种', ?, '使用')
                """, id, "CUR-PROC-" + suffix + "-" + id.toString().substring(0, 8), rate);
        return id;
    }

    private UUID supplier(
            UUID categoryId,
            String status,
            boolean internal,
            boolean deleted,
            String label) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO suppliers(
                    id,category_id,code,name,status,is_internal_workshop,is_deleted,code_sequence)
                VALUES (?,?,?,?,?,?,?,(SELECT COALESCE(max(code_sequence),0)+1 FROM suppliers))
                """, id, categoryId, "GY" + String.format("%06d", supplierCodeSequence++),
                label, status, internal, deleted);
        return id;
    }

    private UUID purchase(
            UUID goods,
            UUID supplier,
            UUID settlement,
            UUID currency,
            BigDecimal taxRate,
            BigDecimal price,
            boolean deleted,
            OffsetDateTime createdAt,
            int sequence) {
        UUID order = UUID.randomUUID();
        String billNo = "CD20260829" + String.format("%06d", 980000 + sequence);
        jdbc.update("""
                INSERT INTO purchase_orders(
                    id,bill_no,bill_date,supplier_id,settlement_method_id,currency_id,
                    tax_rate,status,is_deleted,created_at)
                VALUES (?,?,DATE '2026-08-29',?,?,?,?,0,?,?)
                """, order, billNo, supplier, settlement, currency, taxRate, deleted, createdAt);
        jdbc.update("""
                INSERT INTO purchase_order_items(
                    id,bill_no,bill_date,order_id,goods_id,qty,price,goods_snapshot_source)
                VALUES (?,?,DATE '2026-08-29',?,?,1,?,'MASTER_AT_SAVE')
                """, UUID.randomUUID(), billNo, order, goods, price);
        return order;
    }

    private UUID subcontract(
            UUID goods,
            UUID supplier,
            UUID settlement,
            UUID currency,
            BigDecimal taxRate,
            BigDecimal price,
            boolean deleted,
            OffsetDateTime createdAt,
            int sequence) {
        UUID order = UUID.randomUUID();
        String billNo = "EO20260829" + String.format("%06d", 980000 + sequence);
        jdbc.update("""
                INSERT INTO subcontract_orders(
                    id,bill_no,bill_date,supplier_id,settlement_method_id,currency_id,
                    tax_rate,status,is_deleted,created_at)
                VALUES (?,?,DATE '2026-08-29',?,?,?,?,0,?,?)
                """, order, billNo, supplier, settlement, currency, taxRate, deleted, createdAt);
        jdbc.update("""
                INSERT INTO subcontract_order_items(
                    id,bill_no,bill_date,order_id,goods_id,qty,price,goods_snapshot_source)
                VALUES (?,?,DATE '2026-08-29',?,?,1,?,'MASTER_AT_SAVE')
                """, UUID.randomUUID(), billNo, order, goods, price);
        return order;
    }

    private static String shortId(UUID id) {
        return id.toString().replace("-", "").substring(0, 12).toUpperCase(java.util.Locale.ROOT);
    }

}
