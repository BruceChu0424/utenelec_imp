package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V632 出货放行记账汇率的迁移契约。
 *
 * <p>三条不能回退的口径：① 放行事件表只加两列(汇率 + 来源)且成对约束，不加表、不回填历史事件
 * (V632 之前的放行没有冻结汇率，仓库出库仍回落到币种主档)；② 来源值域只有主档/财务手填两种；
 * ③ 标准收付款方式只在库里没有任何已确认方式时播种，固定 UUID + ON CONFLICT 幂等，
 * 不覆盖旧库 RecStyle 占位行、不改 legacy_name_confirmed 语义。
 */
class SalesShipmentFinanceReleaseRateMigrationContractTest {

    private static final String MIGRATION =
            "db/migration/V632__sales_shipment_finance_release_rate.sql";

    @Test
    void v632AddsRateAndSourceColumnsAsAPairWithoutBackfill() throws IOException {
        String sql = resource(MIGRATION);

        assertThat(sql)
                .contains("ALTER TABLE sales_shipment_finance_release_events")
                .contains("ADD COLUMN exchange_rate        NUMERIC(18,6)")
                .contains("ADD COLUMN exchange_rate_source VARCHAR(20)")
                .contains("CHECK (exchange_rate IS NULL OR exchange_rate > 0)")
                .contains("IN ('CURRENCY_MASTER', 'FINANCE_MANUAL')")
                .contains("CHECK ((exchange_rate IS NULL) = (exchange_rate_source IS NULL))")
                .doesNotContain("UPDATE sales_shipment_finance_release_events")
                .doesNotContain("UPDATE sales_shipments")
                .doesNotContain("CREATE TABLE");
    }

    @Test
    void v632DocumentsTheNewRateSemanticsWithPlainStringComments() throws IOException {
        String sql = resource(MIGRATION);

        assertThat(sql)
                .contains("COMMENT ON COLUMN sales_shipment_finance_release_events.exchange_rate IS")
                .contains("COMMENT ON COLUMN sales_shipment_finance_release_events.exchange_rate_source IS")
                .contains("COMMENT ON COLUMN sales_shipments.exchange_rate IS")
                // COMMENT ON ... IS 只接受单字符串字面量，不得拼接表达式。
                .doesNotContainPattern("COMMENT ON COLUMN[^;]*\\|\\|");
    }

    @Test
    void v632SeedsStandardPaymentMethodsOnlyWhenNothingIsConfirmed() throws IOException {
        String sql = resource(MIGRATION);

        assertThat(sql)
                .contains("INSERT INTO finance_payment_methods")
                .contains("'REC-BANK',   '银行转账'")
                .contains("'REC-CASH',   '现金'")
                .contains("'REC-CHEQUE', '支票'")
                .contains("'REC-DRAFT',  '承兑汇票'")
                .contains("WHERE NOT EXISTS (")
                .contains("WHERE existing.legacy_name_confirmed")
                .contains("ON CONFLICT (code) DO NOTHING")
                // 不得改写旧库占位行的名称或确认标记。
                .doesNotContain("UPDATE finance_payment_methods");
    }

    @Test
    void v632UsesOnlyAsciiParenthesesInNewText() throws IOException {
        String sql = resource(MIGRATION);
        assertThat(sql).doesNotContain("（").doesNotContain("）");
    }

    private static String resource(String path) throws IOException {
        try (var in = SalesShipmentFinanceReleaseRateMigrationContractTest.class
                .getClassLoader().getResourceAsStream(path)) {
            assertThat(in).as(path).isNotNull();
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
    }
}
