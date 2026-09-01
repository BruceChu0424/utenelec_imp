package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class WarehouseArrivalExceptionStockInBatchMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V433__warehouse_arrival_exception_stock_in_batches.sql");

    @Test
    void v433CreatesActorScopedReplayLedgerAndImmutableReceiptResults()
            throws Exception {
        assertThat(MIGRATION).isRegularFile();
        String sql = Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .replaceAll("\s+", " ")
                .toLowerCase(Locale.ROOT);

        assertThat(sql)
                .contains("create table warehouse_arrival_exception_stock_in_batches")
                .contains("create table warehouse_arrival_exception_stock_in_batch_items")
                .contains("unique (actor_user_id, idempotency_key)")
                .contains("request_hash char(64) not null")
                .contains("requested_exception_count between 1 and 100")
                .contains("submitted_for_inspection = true")
                .contains("result_snapshot jsonb")
                .contains("references procurement_arrival_exceptions(id) on delete restrict")
                .contains("unique (batch_id, arrival_exception_id)")
                .contains("result_status in ('receipt_posted', 'closed')")
                .contains("warehouse arrival stock-in batches are append-only")
                .contains("warehouse arrival stock-in batch items are append-only")
                .contains("execute function fn_audit()")
                .doesNotContain("drop table")
                .doesNotContain("flyway_schema_history");
    }

    @Test
    void v433DoesNotClaimThatReceiptSubmissionIsUsableInventory() throws Exception {
        String sql = Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .toLowerCase(Locale.ROOT);

        assertThat(sql)
                .contains("existing receipt-approval/iqc pipeline")
                .contains("not proof of usable inventory")
                .doesNotContain("update stock_balances");
    }
}
