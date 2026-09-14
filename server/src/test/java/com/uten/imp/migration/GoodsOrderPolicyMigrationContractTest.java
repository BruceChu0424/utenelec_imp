package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V575 货品采购批量口径（最小起订量 / 订货倍数）的迁移契约。
 *
 * <p>两列刻意取不同的 CHECK 口径：起订量允许 0（= 已确认「无起订量」，与 NULL
 * 「还没登记」语义不同），倍数必须 &gt; 0（要参与「向上取整到倍数」的除法，0 会除零）。
 * 这里锁住这份差异，防后续「统一成 &gt;= 0」把除零缺口放回来。
 */
class GoodsOrderPolicyMigrationContractTest {

    private static final String MIGRATION =
            "db/migration/V575__goods_order_policy.sql";

    @Test
    void v575AddsBothNullableOrderPolicyColumns() throws IOException {
        String sql = resource(MIGRATION);

        assertThat(sql)
                .contains("ALTER TABLE goods")
                .contains("min_order_qty       NUMERIC(18,4)")
                .contains("order_multiple_qty  NUMERIC(18,4)")
                // 可空：不得出现 NOT NULL / DEFAULT 回填（存量货品没有这两个数字）。
                .doesNotContain("min_order_qty NUMERIC(18,4) NOT NULL")
                .doesNotContain("order_multiple_qty NUMERIC(18,4) NOT NULL");
    }

    @Test
    void v575GuardsNonNegativeMoqAndStrictlyPositiveMultiple() throws IOException {
        String sql = resource(MIGRATION);

        assertThat(sql)
                .contains("goods_order_policy_qty_chk")
                .contains("min_order_qty IS NULL OR min_order_qty >= 0")
                .contains("order_multiple_qty IS NULL OR order_multiple_qty > 0");
        // 倍数不能退回 >= 0：0 会让「向上取整到倍数」除零。
        assertThat(sql).doesNotContain("order_multiple_qty >= 0");
    }

    @Test
    void v575DocumentsBothColumnsWithPlainStringComments() throws IOException {
        String sql = resource(MIGRATION);

        assertThat(sql)
                .contains("COMMENT ON COLUMN goods.min_order_qty IS")
                .contains("COMMENT ON COLUMN goods.order_multiple_qty IS")
                // PostgreSQL 的 COMMENT ON ... IS 只接受单个字符串字面量：
                // 不能拼接（||）也不能用表达式。
                .doesNotContain("COMMENT ON COLUMN goods.min_order_qty IS\n    '' ||")
                .doesNotContain("|| '");
    }

    @Test
    void v575IsColumnOnlyAndTouchesNoResetOrAuditTableAllowlist() throws IOException {
        String sql = resource(MIGRATION);

        // 只加列：没有新表 -> 审计触发器 allowlist 与清库 CLEAR/PRESERVE 名单都不用改。
        // （注释里可以解释为什么不用改，但不能真去动这两份清单。）
        assertThat(sql)
                .doesNotContain("CREATE TABLE")
                .doesNotContain("INSERT INTO business_data_reset_policies")
                .doesNotContain("CREATE OR REPLACE FUNCTION business_data_reset")
                .doesNotContain("audit_trigger_coverage(");
        // 软约束：迁移不得顺手建触发器/规则去硬拦下达数量。
        assertThat(sql)
                .doesNotContain("CREATE TRIGGER")
                .doesNotContain("CREATE RULE");
    }

    private static String resource(String path) throws IOException {
        try (var stream = GoodsOrderPolicyMigrationContractTest.class
                .getClassLoader().getResourceAsStream(path)) {
            assertThat(stream).as(path).isNotNull();
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }
    }
}
