package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;

class WarehouseArrivalRegistrationIdempotencyMigrationContractTest {

    @Test
    void v419AddsNonemptySafeMakerScopedAppendOnlyCommandLedger()
            throws IOException {
        String sql = resource(
                "db/migration/V419__warehouse_arrival_registration_idempotency.sql");

        assertThat(sql)
                .contains("CREATE TABLE warehouse_arrival_registration_commands")
                .contains("maker_id                 UUID NOT NULL REFERENCES employees(id)")
                .contains("idempotency_key          VARCHAR(128) NOT NULL")
                .contains("request_hash             CHAR(64) NOT NULL")
                .contains("UNIQUE (maker_id, idempotency_key)")
                .contains("status = 'PENDING'")
                .contains("status = 'COMPLETED'")
                .contains("status = 'QUARANTINED'")
                .contains("warehouse_arrival_registration_command_identity_guard")
                .contains("warehouse_arrival_registration_command_terminal_guard")
                .contains("ENABLE ALWAYS TRIGGER trg_guard_warehouse_arrival_registration_command")
                .contains("trg_audit_warehouse_arrival_registration_commands")
                .doesNotContain("UPDATE purchase_receipts")
                .doesNotContain("UPDATE subcontract_receipts")
                .doesNotContain("INSERT INTO warehouse_arrival_registration_commands\nSELECT");
    }

    private static String resource(String path) throws IOException {
        try (var stream = WarehouseArrivalRegistrationIdempotencyMigrationContractTest.class
                .getClassLoader().getResourceAsStream(path)) {
            assertThat(stream).as(path).isNotNull();
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }
    }
}
