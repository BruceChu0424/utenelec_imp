package com.uten.imp.features.sales.report;

import com.uten.imp.common.finance.CurrencyDisplayLabel;
import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SalesOrderBilledAmountsPostgresTest {
    static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine");
    static JdbcTemplate db;
    static final UUID ORDER = UUID.randomUUID(), ITEM = UUID.randomUUID(), CURRENCY = UUID.randomUUID();

    @BeforeAll static void start() {
        PG.start();
        db = new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()));
        MigratedProjectionSchema.createCurrentTables(db, "sales_order_items", "sales_shipments", "sales_shipment_items", "currencies");
    }
    @AfterAll static void stop() { PG.stop(); }
    @BeforeEach void reset() {
        db.execute("TRUNCATE sales_order_items,sales_shipments,sales_shipment_items,currencies");
        db.update("INSERT INTO sales_order_items(id,order_id,is_deleted) VALUES (?,?,false)", ITEM, ORDER);
    }

    void shipment(String stage, int status, boolean deleted, String currency, String local) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO sales_shipments(id,status,finance_audit,warehouse_work_status,shipment_kind,is_deleted,currency_id) VALUES (?,?,1,?,'STANDARD',?,?)",
                id, status, stage, deleted, UUID.fromString(currency));
        db.update("INSERT INTO sales_shipment_items(id,shipment_id,order_item_id,is_deleted,amount_local) VALUES (?,?,?,false,?)",
                UUID.randomUUID(), id, ITEM, local == null ? null : new BigDecimal(local));
    }
    BigDecimal read(boolean item) {
        String id = "'" + (item ? ITEM : ORDER) + "'::uuid";
        String body = item ? SalesOrderBilledAmounts.forItem("source.id", "source.currency_id")
                : SalesOrderBilledAmounts.forOrder("source.id", "source.currency_id");
        return db.queryForObject("SELECT billed.amount FROM (SELECT " + id + " AS id,'" + CURRENCY
                + "'::uuid AS currency_id) source CROSS JOIN LATERAL (" + body + ") billed", BigDecimal.class);
    }

    @Test void sumUsesActualPartialShipmentRatesAndExcludesPendingReversedAndOtherCurrencies() {
        shipment("SHIPPED", 1, false, CURRENCY.toString(), "130.4800");
        shipment("SHIPPED", 1, false, CURRENCY.toString(), "131.2256");
        shipment("PENDING_PICK", 0, false, CURRENCY.toString(), "9999");
        shipment("SHIPPED", -1, false, CURRENCY.toString(), "9999");
        shipment("SHIPPED", 1, true, CURRENCY.toString(), "9999");
        shipment("SHIPPED", 1, false, UUID.randomUUID().toString(), "9999");
        assertThat(read(true)).isEqualByComparingTo("261.7056");
        assertThat(read(false)).isEqualByComparingTo("261.7056");
    }
    @Test void missingBillingAmountDoesNotBecomeAFalseZero() {
        shipment("SHIPPED", 1, false, CURRENCY.toString(), null);
        assertThat(read(false)).isNull();
    }
    @Test void standardEnglishCurrencyNamesUseChineseWithoutChangingIdentity() {
        db.update("INSERT INTO currencies(id,name,code) VALUES (?,'US Dollar','002')", CURRENCY);
        assertThat(db.queryForObject("SELECT " + CurrencyDisplayLabel.sql("currency")
                + " FROM currencies currency", String.class)).isEqualTo("美金");
        assertThat(CurrencyDisplayLabel.of("US Dollar", "002")).isEqualTo("美金");
        db.update("UPDATE currencies SET name='Swiss Franc',code='CHF'");
        assertThat(db.queryForObject("SELECT " + CurrencyDisplayLabel.sql("currency")
                + " FROM currencies currency", String.class)).isEqualTo("瑞士法郎");
        assertThat(CurrencyDisplayLabel.of("Swiss Franc", "CHF")).isEqualTo("瑞士法郎");
        assertThat(db.queryForObject("SELECT id FROM currencies", UUID.class)).isEqualTo(CURRENCY);
        assertThat(CurrencyDisplayLabel.of(null, "002")).isNull();
    }
    @Test void currencyLabelsPreferChineseNamesAndNeverInferLegacyNumericCodes() {
        db.update("INSERT INTO currencies(id,name,code) VALUES (?,'美金','002')", CURRENCY);
        assertThat(db.queryForObject("SELECT " + CurrencyDisplayLabel.sql("currency")
                + " FROM currencies currency", String.class)).isEqualTo("美金");
        assertThat(CurrencyDisplayLabel.of(null, "CNY")).isEqualTo("人民币");
        assertThat(CurrencyDisplayLabel.of("USD", "002")).isEqualTo("美金");
        assertThat(CurrencyDisplayLabel.of("US Dollar", "USD")).isEqualTo("美金");
        assertThat(CurrencyDisplayLabel.of("美元", "USD")).isEqualTo("美元");
        assertThat(CurrencyDisplayLabel.of(null, "002")).isNull();
        db.update("UPDATE currencies SET name='US Dollar',code='USD'");
        assertThat(db.queryForObject("SELECT " + CurrencyDisplayLabel.sql("currency")
                + " FROM currencies currency", String.class)).isEqualTo("美金");
    }
}
