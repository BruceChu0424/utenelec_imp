package com.uten.imp.features.finance.arap;

import com.uten.imp.common.finance.PartyOpenBalanceView;
import com.uten.imp.common.finance.PartyOpenBalances;
import com.uten.imp.support.MigratedProjectionSchema;
import org.hibernate.Session;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import java.util.function.Function;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-128 共用往来余额查询跑真 PostgreSQL(当前迁移的列形状): 多币种精确求和、客户预收、退货红字、
 * 旧系统迁入余额、本位币缺原币、外币缺原币 / 缺币种、供应商贷项与预付; 已结清 / 已删除 / 已红冲的行不算,
 * AR 与 AP 互不串, 一次只取请求的往来单位。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PartyOpenBalanceQueryPostgresTest {
    private static final PostgreSQLContainer<?> PG = new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate jdbc;
    private static SessionFactory sessions;

    private UUID cny, usd, hkd, party, other, run;
    private int billSequence;

    @BeforeAll
    static void start() {
        PG.start();
        jdbc = new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()));
        MigratedProjectionSchema.createCurrentTables(jdbc, "currencies", "ar_ap_ledger", "legacy_finance_import_sources");
        sessions = new Configuration().setProperty("hibernate.connection.url", PG.getJdbcUrl())
                .setProperty("hibernate.connection.username", PG.getUsername())
                .setProperty("hibernate.connection.password", PG.getPassword())
                .setProperty("hibernate.hbm2ddl.auto", "none").buildSessionFactory();
    }

    @AfterAll
    static void stop() {
        if (sessions != null) sessions.close();
        PG.stop();
    }

    @BeforeEach
    void seed() {
        jdbc.execute("TRUNCATE currencies, ar_ap_ledger, legacy_finance_import_sources");
        cny = currency("001", "人民币", true);
        usd = currency("002", "美金", false);
        hkd = currency("003", "港币", false);
        party = UUID.randomUUID();
        other = UUID.randomUUID();
        run = UUID.randomUUID();
    }

    @Test
    void clientBalanceIsExactPerCurrencyWithGrossCreditExposureAndUnverifiedHistorySeparated() {
        // 美金: 发货 1000(账面 7000)、部分收款后剩 300(账面 2100)、退货红字 -100(账面 -700)、预收 200(账面 1400)。
        ar(usd, "RECEIVABLE", "SALES_SHIPMENT", "1000", "7000");
        ar(usd, "RECEIVABLE", "SALES_SHIPMENT", "300", "2100");
        ar(usd, "RECEIVABLE", "SALES_RETURN", "-100", "-700");
        ar(usd, "CUSTOMER_PREPAYMENT", "DIRECT_RECEIPT", "-200", "-1400");
        // 人民币(本位币): 5000; 另一行没有原币, 本位币按账面本币 250 计。
        ar(cny, "RECEIVABLE", "SALES_SHIPMENT", "5000", "5000");
        ar(cny, "RECEIVABLE", "SALES_SHIPMENT", null, "250");
        // 原币未核实: 美金行缺原币(账面 560)、缺币种(账面 90)、旧系统迁入(账面 210)。
        ar(usd, "RECEIVABLE", "SALES_SHIPMENT", null, "560");
        ar(null, "RECEIVABLE", "SALES_SHIPMENT", null, "90");
        legacyOpening(usd, "30", "210");
        // 不算: 已结清、已删除、已红冲、别的客户、同一 id 的应付行。
        UUID settled = ar(usd, "RECEIVABLE", "SALES_SHIPMENT", "0", "0");
        jdbc.update("UPDATE ar_ap_ledger SET is_settled=TRUE WHERE id=?", settled);
        UUID deleted = ar(usd, "RECEIVABLE", "SALES_SHIPMENT", "999", "6993");
        jdbc.update("UPDATE ar_ap_ledger SET is_deleted=TRUE WHERE id=?", deleted);
        UUID reversed = ar(usd, "RECEIVABLE", "SALES_SHIPMENT", "888", "6216");
        jdbc.update("UPDATE ar_ap_ledger SET status=-1 WHERE id=?", reversed);
        ledger("AR", other, usd, "RECEIVABLE", "SALES_SHIPMENT", "77777", "77777", null);
        ledger("AP", party, cny, "PAYABLE", "PURCHASE_RECEIPT", "12345", "12345", null);

        PartyOpenBalances balances = query(q -> q.clients(List.of(party)));
        assertThat(balances.parties()).containsOnlyKeys(party);

        PartyOpenBalanceView usdView = balances.forDocument(party, usd, new BigDecimal("20000"));
        assertThat(usdView.currencyName()).isEqualTo("美金");
        assertThat(usdView.openOriginal()).isEqualByComparingTo("1200");
        assertThat(usdView.creditOriginal()).isEqualByComparingTo("200");
        assertThat(usdView.netOriginal()).isEqualByComparingTo("1000");
        assertThat(usdView.creditBookLocal()).isEqualByComparingTo("1400");
        assertThat(usdView.otherCurrencies()).singleElement().satisfies(bucket -> {
            assertThat(bucket.currencyName()).isEqualTo("人民币");
            assertThat(bucket.baseCurrency()).isTrue();
            assertThat(bucket.netOriginal()).isEqualByComparingTo("5250");
        });
        // 信用口径: 全部币种正式应收账面本币(含原币未核实的外币行), 不扣预收, 不含旧系统迁入行。
        assertThat(usdView.openBookLocal()).isEqualByComparingTo("14300");
        assertThat(usdView.unverifiedLocal()).isEqualByComparingTo("860");
        assertThat(usdView.unverifiedCount()).isEqualTo(3);
        assertThat(usdView.baseCurrencyName()).isEqualTo("人民币");
        assertThat(usdView.overLimitLocal()).isEqualByComparingTo("-5700");
        assertThat(usdView.overCredit()).isFalse();
        // 扣掉预收是 12900, 低于 14000; 按毛额 14300 已超。
        assertThat(balances.forDocument(party, usd, new BigDecimal("14000")).overCredit()).isTrue();

        PartyOpenBalanceView cnyView = balances.forDocument(party, cny, null);
        assertThat(cnyView.baseCurrency()).isTrue();
        assertThat(cnyView.netOriginal()).isEqualByComparingTo("5250");
        assertThat(cnyView.otherCurrencies()).singleElement()
                .satisfies(bucket -> assertThat(bucket.netOriginal()).isEqualByComparingTo("1000"));

        PartyOpenBalanceView hkdView = balances.forDocument(party, hkd, null);
        assertThat(hkdView.currencyName()).isEqualTo("港币");
        assertThat(hkdView.netOriginal()).isEqualByComparingTo("0");
        assertThat(hkdView.otherCurrencies()).hasSize(2);
    }

    @Test
    void prepaymentSurplusShowsAsNegativeNetAndPartiesWithoutOpenItemsAreZero() {
        ar(usd, "CUSTOMER_PREPAYMENT", "DIRECT_RECEIPT", "-100", "-700");
        ar(usd, "CUSTOMER_PREPAYMENT", "DIRECT_RECEIPT", "-100", "-700");
        UUID quiet = UUID.randomUUID();

        PartyOpenBalances balances = query(q -> q.clients(List.of(party, quiet)));

        PartyOpenBalanceView view = balances.forDocument(party, usd, null);
        assertThat(view.netOriginal()).isEqualByComparingTo("-200");
        assertThat(view.openBookLocal()).isEqualByComparingTo("0");
        assertThat(balances.forDocument(quiet, usd, null).netOriginal()).isEqualByComparingTo("0");
        assertThat(query(q -> q.clients(List.of())).parties()).isEmpty();
    }

    @Test
    void supplierBalanceNetsPayablesAgainstCreditsClaimsAndPrepaymentsInTheOrderCurrency() {
        ledger("AP", party, cny, "PAYABLE", "PURCHASE_RECEIPT", "12345", "12345", null);
        ledger("AP", party, cny, "CREDIT", "PURCHASE_RETURN", "-345", "-345", null);
        ledger("AP", party, cny, "CLAIM_CREDIT", "SUBCONTRACT_LOSS_OFFSET", "-100", "-100", null);
        ledger("AP", party, cny, "PREPAYMENT", "DIRECT_PAYMENT", "-1000", "-1000", null);
        ledger("AP", party, usd, "PAYABLE", "SUBCONTRACT_RECEIPT", "50", "350", null);
        ledger("AR", party, cny, "RECEIVABLE", "SALES_SHIPMENT", "999", "999", null);

        PartyOpenBalanceView view = query(q -> q.suppliers(List.of(party))).forDocument(party, cny, null);

        assertThat(view.openOriginal()).isEqualByComparingTo("12345");
        assertThat(view.creditOriginal()).isEqualByComparingTo("1445");
        assertThat(view.netOriginal()).isEqualByComparingTo("10900");
        assertThat(view.otherCurrencies()).singleElement().satisfies(bucket -> {
            assertThat(bucket.currencyName()).isEqualTo("美金");
            assertThat(bucket.netOriginal()).isEqualByComparingTo("50");
        });
        assertThat(view.openBookLocal()).isEqualByComparingTo("12695");
        assertThat(view.unverifiedLocal()).isEqualByComparingTo("0");
        assertThat(view.overCredit()).isFalse();
    }

    @Test
    void sqlKeepsTheDirectionLiteralForThePartialIndexes() {
        assertThat(PartyOpenBalanceQuery.CLIENT_SQL).contains("ledger.direction = 'AR'", "ledger.client_id IN (:partyIds)");
        assertThat(PartyOpenBalanceQuery.SUPPLIER_SQL).contains("ledger.direction = 'AP'", "ledger.supplier_id IN (:partyIds)");
    }

    private PartyOpenBalances query(Function<PartyOpenBalanceQuery, PartyOpenBalances> call) {
        try (Session session = sessions.openSession()) {
            var transaction = session.beginTransaction();
            try {
                return call.apply(new PartyOpenBalanceQuery(session));
            } finally {
                transaction.rollback();
            }
        }
    }

    private UUID currency(String code, String name, boolean base) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO currencies(id,code,name,status,is_base_currency) VALUES (?,?,?,'使用',?)",
                id, code, name, base);
        return id;
    }

    private UUID ar(UUID currency, String kind, String sourceType, String balanceOriginal, String balance) {
        return ledger("AR", party, currency, kind, sourceType, balanceOriginal, balance, null);
    }

    private void legacyOpening(UUID currency, String balanceOriginal, String balance) {
        UUID id = ledger("AR", party, currency, "LEGACY_UNVERIFIED", "LEGACY_OPENING", balanceOriginal, balance, run);
        jdbc.update("""
                INSERT INTO legacy_finance_import_sources(run_id,target_id,target_table,initial_state)
                VALUES (?,?,'ar_ap_ledger',jsonb_build_object('amount_balance',CAST(? AS numeric),
                    'amount_balance_original',CAST(? AS numeric)))
                """, run, id, new BigDecimal(balance), new BigDecimal(balanceOriginal));
    }

    private UUID ledger(String direction, UUID partyId, UUID currency, String kind, String sourceType,
                        String balanceOriginal, String balance, UUID importRun) {
        UUID id = UUID.randomUUID();
        BigDecimal original = balanceOriginal == null ? null : new BigDecimal(balanceOriginal);
        BigDecimal local = new BigDecimal(balance);
        jdbc.update("""
                INSERT INTO ar_ap_ledger(id,direction,source_doc_type,bill_no,bill_date,client_id,supplier_id,
                    currency_id,amount_original,amount_original_local,amount_balance,amount_balance_original,
                    open_item_kind,status,is_deleted,is_settled,legacy_import_run_id,business_type)
                VALUES (?,?,?,?,DATE '2026-09-27',?,?,?,?,?,?,?,?,1,FALSE,FALSE,?,'SALES')
                """, id, direction, sourceType, "B" + (++billSequence),
                "AR".equals(direction) ? partyId : null, "AP".equals(direction) ? partyId : null,
                currency, original == null ? local : original, local, local, original, kind, importRun);
        return id;
    }
}
