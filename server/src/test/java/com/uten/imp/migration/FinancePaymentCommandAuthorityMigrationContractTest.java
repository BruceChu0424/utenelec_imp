package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;

class FinancePaymentCommandAuthorityMigrationContractTest {

    @Test
    void v417AddsMakerScopedCreateIdempotencyAndOptimisticVersioning()
            throws IOException {
        String sql = resource(
                "db/migration/V417__finance_payment_command_idempotency.sql");

        assertThat(sql)
                .contains("ADD COLUMN version BIGINT NOT NULL DEFAULT 0")
                .contains("create_idempotency_key VARCHAR(128)")
                .contains("create_request_hash VARCHAR(64)")
                .contains("finance_payments_create_command_shape_chk")
                .contains("create_request_hash IS NOT NULL")
                .contains("create_request_hash ~ '^[0-9a-f]{64}$'")
                .contains("CREATE UNIQUE INDEX uq_finance_payments_create_idempotency")
                .contains("ON finance_payments(maker_id, create_idempotency_key)")
                .contains("fn_guard_finance_payment_create_command")
                .contains("finance_payments_create_command_immutable_guard")
                .doesNotContain("UPDATE finance_payments")
                .doesNotContain("DELETE FROM finance_payments");
    }

    private static String resource(String path) throws IOException {
        try (var stream = FinancePaymentCommandAuthorityMigrationContractTest.class
                .getClassLoader().getResourceAsStream(path)) {
            assertThat(stream).as(path).isNotNull();
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }
    }
}
