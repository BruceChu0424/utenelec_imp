package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/** Static safety contract for V189's customer-return quarantine ledger. */
class SalesReturnQualityQuarantineMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/V189__sales_return_quality_quarantine.sql");

    @Test
    void quarantineProjectionCannotOverDisposeAndIsOutsideSaleableStock() throws IOException {
        String sql = sql();
        assertThat(sql)
                .contains("sales_return_quality_items")
                .contains("released_base_qty + scrapped_base_qty + rework_base_qty <= received_base_qty")
                .contains("status IN ('PENDING', 'PARTIAL', 'DISPOSED', 'REVERSED')")
                .doesNotContain("INSERT INTO stock_balances")
                .doesNotContain("UPDATE stock_balances");
    }

    @Test
    void historyIsNotBackfilledAndEvidenceIsAppendOnlyAudited() throws IOException {
        assertThat(sql())
                .contains("sales_return_quality_events")
                .contains("BEFORE UPDATE OR DELETE")
                .contains("ENABLE ALWAYS TRIGGER")
                .contains("trg_audit_sales_return_quality_items")
                .contains("trg_audit_sales_return_quality_events")
                .contains("sales_return_quality:handle")
                .doesNotContain("SELECT id FROM sales_returns")
                .doesNotContain("INSERT INTO sales_return_quality_items SELECT");
    }

    private static String sql() throws IOException {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8);
    }
}
