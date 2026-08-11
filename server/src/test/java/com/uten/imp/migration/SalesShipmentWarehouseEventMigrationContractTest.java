package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/** Static contract for V188's immutable warehouse transition evidence. */
class SalesShipmentWarehouseEventMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V188__sales_shipment_warehouse_event_ledger.sql");

    @Test
    void transitionReasonsAreDurableAndHistoricallyHonest()
            throws IOException {
        String sql = sql();

        assertThat(sql)
                .contains("sales_shipment_warehouse_events")
                .contains("from_status TEXT")
                .contains("to_status TEXT NOT NULL")
                .contains("reason TEXT")
                .contains("occurred_at TIMESTAMPTZ NOT NULL")
                .contains("to_status = 'PENDING_PICK'")
                .doesNotContain("INSERT INTO sales_shipment_warehouse_events")
                .doesNotContain("SELECT id FROM sales_shipments");
    }

    @Test
    void evidenceIsAppendOnlyAndDatabaseAudited() throws IOException {
        assertThat(sql())
                .contains("BEFORE UPDATE OR DELETE")
                .contains("ENABLE ALWAYS TRIGGER")
                .contains("is append-only")
                .contains("trg_audit_sales_shipment_warehouse_events")
                .contains("EXECUTE FUNCTION fn_audit()");
    }

    private static String sql() throws IOException {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8);
    }
}
