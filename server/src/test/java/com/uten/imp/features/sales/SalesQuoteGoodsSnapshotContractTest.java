package com.uten.imp.features.sales;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class SalesQuoteGoodsSnapshotContractTest {

    @Test
    void quotationMigrationBackfillsAndFreezesExplicitlyProvenancedSnapshots()
            throws IOException {
        String sql = compact(read(Path.of(
                "src/main/resources/db/migration/V271__sales_quote_goods_history_snapshots.sql")));

        assertThat(sql)
                .contains("alter table sales_quote_items add column goods_code_snapshot text,")
                .contains("add column goods_name_snapshot text,")
                .contains("add column goods_snapshot_source text,")
                .contains("add column goods_snapshot_locked_at timestamptz")
                .contains("goods_snapshot_source = 'backfill_v271'")
                .contains("case when document.status <> 0 then now() else null end")
                .contains("alter column goods_snapshot_source set not null")
                .contains("'legacy_import', 'master_at_save', 'master_at_approval'");
    }

    @Test
    void saveAndApprovalPathsUseTheGoodsUuidToCaptureHistoricalLabels()
            throws IOException {
        String service = compact(read(Path.of(
                "src/main/java/com/uten/imp/features/sales/quote/SalesQuoteService.java")));

        assertThat(service)
                .contains("salesgoodssnapshot.frommaster(")
                .contains("salesgoodssnapshot.master_at_save")
                .contains("salesgoodssnapshot.master_at_approval")
                .contains("items.stream().map(salesquoteitem::getgoodsid).tolist()")
                .contains("setgoodscodesnapshot(snapshot.code())")
                .contains("setgoodssnapshotlockedat(lockedat)");
    }

    @Test
    void legacyImportSuppliesTheRequiredQuotationSnapshotColumns()
            throws IOException {
        String sql = compact(read(Path.of("legacy_migration/migrate_sales.sql")));

        assertThat(sql)
                .contains("insert into sales_quote_items (")
                .contains("goods_code_snapshot, goods_name_snapshot, goods_snapshot_source, goods_snapshot_locked_at")
                .contains("'legacy_import', case when coalesce(q.status, 0) <> 0 then now() else null end");
    }

    private static String read(Path path) throws IOException {
        return Files.readString(path, StandardCharsets.UTF_8);
    }

    private static String compact(String value) {
        return value.toLowerCase(Locale.ROOT).replaceAll("\\s+", " ").trim();
    }
}
