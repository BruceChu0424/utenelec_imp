package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;

class GoodsCostIntegrityMigrationContractTest {

    @Test
    void v421PreservesEvidenceBeforeRepairAndAddsValidatedGuards()
            throws IOException {
        String sql = resource(
                "db/migration/V421__goods_cost_integrity_and_ledger_amount.sql");

        assertThat(sql)
                .contains("INSERT INTO audit_log")
                .contains("NEGATIVE_OR_OUT_OF_RANGE_GOODS_COST_OR_RATE")
                .contains("'severity', 'high'")
                .contains("CLAMP_INPUTS_AND_RECOMPUTE_DERIVED_COSTS_V1")
                .contains("audit_log.before.values")
                .contains("UPDATE goods g")
                .contains("goods_cost_amount_range_chk")
                .contains("goods_cost_rate_range_chk")
                .contains("VALIDATE CONSTRAINT goods_cost_amount_range_chk")
                .contains("VALIDATE CONSTRAINT goods_cost_rate_range_chk")
                .contains("work_rate BETWEEN 0 AND 100")
                .contains("c_total BETWEEN 0 AND 99999999999999.9999");

        assertThat(sql)
                .contains("SELECT 'flyway:V421',\n       'update'")
                .doesNotContain("risk_level,", "event_category,")
                .doesNotContain("'data_remediation'");

        assertThat(sql.indexOf("INSERT INTO audit_log"))
                .isLessThan(sql.indexOf("UPDATE goods g"));
    }

    private static String resource(String path) throws IOException {
        try (var stream = GoodsCostIntegrityMigrationContractTest.class
                .getClassLoader().getResourceAsStream(path)) {
            assertThat(stream).as(path).isNotNull();
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }
    }
}
