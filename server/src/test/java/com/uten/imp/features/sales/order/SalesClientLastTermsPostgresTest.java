package com.uten.imp.features.sales.order;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Real PostgreSQL proof for the client master default sales terms
 * (V592 单一事实源: 保存销售订货单写回客户行 -> 新建单一律读客户行预填
 * 结账方式/发运策略/币种)。
 *
 * <p>类名与端点路径 /last-terms 一样是历史遗留, 语义自 V592 起是主档默认值:
 * 「按该客户最近一张订单实时推导」的回退路径已于 2026-09-16 退役。
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
                "uten.jwt.secret=client-terms-harness-jwt-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=client-terms-harness-pgp-key-test-only-012345",
                "uten.crypto.hmac-key=client-terms-harness-hmac-key-test-only",
                "uten.bootstrap.admin-login=client-terms-bootstrap-admin-test",
                "uten.bootstrap.admin-password=ClientTermsAdminPass-1!"
        })
class SalesClientLastTermsPostgresTest {

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
    private SalesOrderService service;

    @Autowired
    private com.uten.imp.features.master.client.ClientDefaultTermsSyncService termsSync;

    @Autowired
    private org.springframework.transaction.PlatformTransactionManager txm;

    /** 同步服务是 MANDATORY 传播（挂单据事务），测试里手动包一层事务。 */
    private void sync(UUID clientId, UUID sm, String sp, UUID cur) {
        new org.springframework.transaction.support.TransactionTemplate(txm)
                .executeWithoutResult(tx -> termsSync.syncOnOrderTerms(clientId, sm, sp, cur));
    }

    @Test
    void learningInvalidatesAnAlreadyOpenMasterEditorWithoutTouchingItOnReplay() {
        UUID clientId = client("VERSION");
        long before = jdbc.queryForObject("SELECT version FROM clients WHERE id=?", Long.class, clientId);
        UUID currency = currency("VERSION");
        sync(clientId, null, "ALLOW_PARTIAL", currency);
        assertThat(jdbc.queryForObject("SELECT version FROM clients WHERE id=?", Long.class, clientId))
                .isEqualTo(before + 1);
        assertThat(jdbc.update("UPDATE clients SET default_shipment_policy='REQUIRE_COMPLETE' WHERE id=? AND version=?",
                clientId, before)).isZero();
        sync(clientId, null, "ALLOW_PARTIAL", currency);
        assertThat(jdbc.queryForObject("SELECT version FROM clients WHERE id=?", Long.class, clientId))
                .isEqualTo(before + 1);
    }

    /** 类级共享：号段触发器要求 XD+日期+6 位序号的注册格式，序号不重复。 */
    private static final java.util.concurrent.atomic.AtomicInteger BILL_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();

    private static String billNo() {
        return "XD20260904%06d".formatted(BILL_SEQUENCE.incrementAndGet());
    }

    /**
     * 预填只认客户行: 订单历史再多, 客户行没有默认值就不预填
     * (旧的「按最近一张订单实时推导」已退役), 也不会串到别的客户。
     */
    @Test
    void masterDefaultsIgnoreOrderHistoryUntilTheClientRowCarriesThem() {
        UUID clientA = client("A");
        UUID clientB = client("B");
        UUID settlementOld = settlement("OLD");
        UUID settlementNew = settlement("NEW");
        UUID currencyOld = currency("OLD");
        UUID currencyNew = currency("NEW");

        OffsetDateTime base = OffsetDateTime.of(
                2026, 9, 4, 8, 0, 0, 0, ZoneOffset.UTC);
        order(clientA, settlementOld, currencyOld, "ALLOW_PARTIAL", base.plusMinutes(1));
        order(clientA, settlementNew, currencyNew, "REQUIRE_COMPLETE", base.plusMinutes(2));
        order(clientB, settlementOld, currencyOld, null, base.plusMinutes(3));

        // ① 客户行三项全空: 不预填 (不再实时扫订单表)。
        assertThat(service.masterDefaultTermsForClient(clientA)).isNull();
        // ② 客户不存在: 同样是 null, 不抛。
        assertThat(service.masterDefaultTermsForClient(UUID.randomUUID())).isNull();

        // ③ 保存订单写回之后才有预填, 而且只写本客户那一行。
        sync(clientA, settlementNew, "REQUIRE_COMPLETE", currencyNew);
        SalesOrderService.MasterDefaultTermsForClient terms =
                service.masterDefaultTermsForClient(clientA);
        assertThat(terms).isNotNull();
        assertThat(terms.settlementMethodId()).isEqualTo(settlementNew);
        assertThat(terms.currencyId()).isEqualTo(currencyNew);
        assertThat(terms.shipmentPolicy()).isEqualTo("REQUIRE_COMPLETE");
        assertThat(service.masterDefaultTermsForClient(clientB)).isNull();
    }

    /**
     * V592 写回真库锁（2026-09-15 生产事故回归）：fn_sync_client_default_
     * settlement_method_reference() 触发器要求 UUID 与 price_style 旧快照成对
     * 一致、且字典必须「使用中」。首版写回只更 UUID 被触发器整单打回
     * （ConstraintViolationException）——本用例在没有触发器知识的前提下必然红。
     */
    @Test
    void writeBackRecordsLatestTermsAndSurvivesTheSettlementShadowTrigger() {
        UUID clientId = client("WB");
        UUID settlementA = settlement("WB-A");
        UUID settlementB = settlement("WB-B");
        UUID disabledSettlement = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO settlement_methods (id, code, name, status)
                VALUES (?, ?, '已停用的结算方式', '禁用')
                """, disabledSettlement, "STM-WB-OFF-" + disabledSettlement.toString().substring(0, 8));
        UUID currencyA = currency("WB-A");
        UUID currencyB = currency("WB-B");

        // 客户行预置：A 作为默认 + 与 A 的 legacy 对齐的 price_style（触发器要求成对）。
        Integer legacyA = jdbc.queryForObject(
                "SELECT legacy_id FROM settlement_methods WHERE id = ?", Integer.class, settlementA);
        jdbc.update("""
                UPDATE clients SET default_settlement_method_id = ?, price_style = ?
                WHERE id = ?
                """, settlementA, legacyA, clientId);
        // version/updated_at 都是 JPA 层管的，裸 SQL 不推；「真的落过盘」用行物理版本
        // xmin 判（任何真实 UPDATE 都换元组）。
        String xminBefore = clientRowXmin(clientId);

        // ① 换仓式写回：B 替代 A，price_style 旧快照非空且不同——首版在这里被
        //    触发器以「UUID conflicts with price_style shadow」打回。
        sync(clientId, settlementB, "REQUIRE_COMPLETE", currencyB);
        assertThat(defaultSettlement(clientId)).isEqualTo(settlementB);
        Integer legacyB = jdbc.queryForObject(
                "SELECT legacy_id FROM settlement_methods WHERE id = ?", Integer.class, settlementB);
        assertThat(shadowPriceStyle(clientId)).isEqualTo(legacyB);
        assertThat(defaultShipment(clientId)).isEqualTo("REQUIRE_COMPLETE");
        assertThat(defaultCurrency(clientId)).isEqualTo(currencyB);
        assertThat(clientRowXmin(clientId)).isNotEqualTo(xminBefore);

        // ② 停用字典保值：订单记着已停用的结账方式时不能写（也不能炸），
        //    货运策略/币种照常记。
        sync(clientId, disabledSettlement, "ALLOW_PARTIAL", currencyA);
        assertThat(defaultSettlement(clientId)).isEqualTo(settlementB);
        assertThat(defaultShipment(clientId)).isEqualTo("ALLOW_PARTIAL");
        assertThat(defaultCurrency(clientId)).isEqualTo(currencyA);

        // ③ 值没变不落盘（xmin 不变 = 没有真实 UPDATE）。
        String xminStable = clientRowXmin(clientId);
        sync(clientId, settlementB, "ALLOW_PARTIAL", currencyA);
        assertThat(clientRowXmin(clientId)).isEqualTo(xminStable);

        // ④ 空项保持原值；⑤ 预填读的是客户行（V592 单一事实源）。
        sync(clientId, null, null, null);
        assertThat(defaultSettlement(clientId)).isEqualTo(settlementB);
        assertThat(defaultShipment(clientId)).isEqualTo("ALLOW_PARTIAL");
        SalesOrderService.MasterDefaultTermsForClient terms =
                service.masterDefaultTermsForClient(clientId);
        assertThat(terms.settlementMethodId()).isEqualTo(settlementB);
        assertThat(terms.shipmentPolicy()).isEqualTo("ALLOW_PARTIAL");
        assertThat(terms.currencyId()).isEqualTo(currencyA);
    }

    private UUID defaultSettlement(UUID clientId) {
        return jdbc.queryForObject(
                "SELECT default_settlement_method_id FROM clients WHERE id = ?",
                UUID.class, clientId);
    }

    private Integer shadowPriceStyle(UUID clientId) {
        return jdbc.queryForObject(
                "SELECT price_style FROM clients WHERE id = ?", Integer.class, clientId);
    }

    private String defaultShipment(UUID clientId) {
        return jdbc.queryForObject(
                "SELECT default_shipment_policy FROM clients WHERE id = ?",
                String.class, clientId);
    }

    private UUID defaultCurrency(UUID clientId) {
        return jdbc.queryForObject(
                "SELECT default_currency_id FROM clients WHERE id = ?",
                UUID.class, clientId);
    }

    private String clientRowXmin(UUID clientId) {
        return jdbc.queryForObject(
                "SELECT xmin::text FROM clients WHERE id = ?",
                String.class, clientId);
    }

    private UUID client(String suffix) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO clients (id, code, name, status, code_sequence)
                VALUES (?, ?, '客户条款学习测试客户', '使用',
                        (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM clients))
                """, id, "CLI-TERMS-" + suffix + "-" + id.toString().substring(0, 8));
        return id;
    }

    private UUID settlement(String suffix) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO settlement_methods (id, code, name, status)
                VALUES (?, ?, '客户条款学习测试结算方式', '使用')
                """, id, "STM-TERMS-" + suffix + "-" + id.toString().substring(0, 8));
        return id;
    }

    private UUID currency(String suffix) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO currencies (id, code, name, exchange_rate, status)
                VALUES (?, ?, '客户条款学习测试币种', 1.000000, '使用')
                """, id, "CUR-TERMS-" + suffix + "-" + id.toString().substring(0, 8));
        return id;
    }

    /** 订单历史夹具: 只用来证明「有订单也不预填」, 预填不再看这张表。 */
    private void order(
            UUID clientId, UUID settlementId, UUID currencyId, String shipmentPolicy,
            OffsetDateTime createdAt) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO sales_orders(
                    id, bill_no, bill_date, client_id, status,
                    settlement_method_id, currency_id, shipment_policy,
                    created_at, updated_at, is_deleted
                ) VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?, false)
                """, id, billNo(),
                LocalDate.of(2026, 9, 4), clientId,
                settlementId, currencyId, shipmentPolicy,
                createdAt, createdAt);
    }
}
