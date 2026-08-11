package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/** Static contract for V187's historical-safe shipment and warehouse workflow. */
class SalesShipmentPolicyMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V187__sales_shipment_policy_and_warehouse_work.sql");

    @Test
    void historicalRowsAreNotRewrittenAsCustomerOrPickingFacts() throws IOException {
        String sql = sql();

        assertThat(sql)
                .contains("SET shipment_policy = 'LEGACY_UNSPECIFIED'")
                .contains("ALTER COLUMN shipment_policy SET DEFAULT 'CUSTOMER_CONFIRM'")
                .contains("ELSE 'LEGACY_PENDING'")
                .contains("ALTER COLUMN warehouse_work_status SET DEFAULT 'PENDING_PICK'")
                .doesNotContain("SET partial_shipment_confirmed_at = now()")
                .doesNotContain("SET picking_started_at = now()");
    }

    @Test
    void databaseConstrainsEveryStableBusinessState() throws IOException {
        assertThat(sql())
                .contains("'ALLOW_PARTIAL'")
                .contains("'REQUIRE_COMPLETE'")
                .contains("'CUSTOMER_CONFIRM'")
                .contains("'PENDING_PICK'")
                .contains("'PICKING'")
                .contains("'PICKED'")
                .contains("'EXCEPTION'")
                .contains("'SHIPPED'")
                .contains("'CANCELLED'")
                .contains("'REVERSED'")
                .contains("sales_orders_shipment_policy_chk")
                .contains("sales_shipments_warehouse_work_status_chk");
    }

    @Test
    void sensitiveActionsUseSeparatePermissions() throws IOException {
        assertThat(sql())
                .contains("'sales_order:confirm_partial_shipment'")
                .contains("'sales_shipment:warehouse-work'")
                .contains("WHERE d.code = 'DEPT_SALES'")
                .contains("WHERE d.code = 'DEPT_PMC'");
    }

    private static String sql() throws IOException {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8);
    }
}
