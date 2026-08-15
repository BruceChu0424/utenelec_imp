package com.uten.imp.features.sales;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class SalesGoodsHistorySnapshotContractTest {

    private static final Path MAIN = Path.of("src/main");
    private static final Path MIGRATION = MAIN.resolve(
            "resources/db/migration/V257__sales_goods_history_snapshots.sql");
    private static final List<String> ITEM_TABLES = List.of(
            "sales_order_items",
            "sales_shipment_items",
            "sales_other_shipment_items",
            "sales_return_items");

    @Test
    void migrationAddsAndBackfillsExplicitlyProvenancedSnapshots() throws IOException {
        String sql = compact(read(MIGRATION));

        for (String table : ITEM_TABLES) {
            assertThat(sql)
                    .contains("alter table " + table
                            + " add column goods_code_snapshot text,"
                            + " add column goods_name_snapshot text,"
                            + " add column goods_snapshot_source text,"
                            + " add column goods_snapshot_locked_at timestamptz")
                    .contains("update " + table + " item set goods_code_snapshot = goods.code,")
                    .contains("alter table " + table
                            + " alter column goods_snapshot_source set not null,")
                    .contains("ck_" + table + "_goods_snapshot_source");
        }

        assertThat(occurrences(sql, "goods_snapshot_source = 'backfill_v257'"))
                .isEqualTo(ITEM_TABLES.size());
        assertThat(occurrences(
                sql,
                "goods_snapshot_locked_at = case when document.status <> 0 then now() else null end"))
                .isEqualTo(ITEM_TABLES.size());
        assertThat(sql)
                .contains("'legacy_import'", "'master_at_save'", "'master_at_approval'",
                        "'order_item_at_save'", "'order_item_at_approval'",
                        "'shipment_item_at_save'", "'shipment_item_at_approval'");
    }

    @Test
    void saveAndApprovalPathsCaptureFromTheCorrectAuthority() throws IOException {
        String order = source("features/sales/order/SalesOrderService.java");
        String shipment = source("features/sales/shipment/SalesShipmentService.java");
        String otherShipment = source(
                "features/sales/other_shipment/SalesOtherShipmentService.java");
        String salesReturn = source("features/sales/ret/SalesReturnService.java");

        assertThat(order)
                .contains("salesgoodssnapshot.master_at_save")
                .contains("salesgoodssnapshot.master_at_approval")
                .contains("setgoodssnapshotlockedat(lockedat)");

        assertThat(shipment)
                .contains("salesgoodssnapshot.order_item_at_save")
                .contains("salesgoodssnapshot.order_item_at_approval")
                .contains("preferredsnapshot(")
                .contains("setgoodssnapshotlockedat(lockedat)");

        assertThat(otherShipment)
                .contains("salesgoodssnapshot.order_item_at_save")
                .contains("salesgoodssnapshot.order_item_at_approval")
                .contains("setgoodssnapshotlockedat(lockedat)");

        assertThat(salesReturn)
                .contains("salesgoodssnapshot.shipment_item_at_save")
                .contains("salesgoodssnapshot.shipment_item_at_approval")
                .contains("salesgoodssnapshot.order_item_at_save")
                .contains("salesgoodssnapshot.order_item_at_approval")
                .contains("setgoodssnapshotlockedat(lockedat)");
    }

    @Test
    void salesDetailReportsProjectAndSearchTheHistoricalCodeAndName() throws IOException {
        String report = read(MAIN.resolve(
                "java/com/uten/imp/features/sales/report/SalesReportService.java"));

        assertThat(occurrences(report, "i.goods_code_snapshot AS \"goodsCode\""))
                .isEqualTo(ITEM_TABLES.size());
        assertThat(occurrences(report, "i.goods_name_snapshot AS \"goodsName\""))
                .isEqualTo(ITEM_TABLES.size());
        assertThat(report)
                .contains("COALESCE(i.goods_name_snapshot,'')")
                .contains("COALESCE(i.goods_code_snapshot,'')")
                .doesNotContain("g.code AS \"goodsCode\"")
                .doesNotContain("g.name AS \"goodsName\"");
    }

    @Test
    void downstreamSnapshotsDoNotFallBackToRenamedMasterLabels() throws IOException {
        String support = source("features/sales/SalesGoodsSnapshot.java");

        assertThat(support)
                .contains("select item.id, item.goods_code_snapshot, item.goods_name_snapshot"
                        + " from sales_order_items item")
                .contains("select item.id, item.goods_code_snapshot, item.goods_name_snapshot"
                        + " from sales_shipment_items item")
                .doesNotContain("coalesce(item.goods_code_snapshot, goods.code)")
                .doesNotContain("coalesce(item.goods_name_snapshot, goods.name)");
    }

    @Test
    void legacySalesImportPopulatesTheNewRequiredSnapshotColumns() throws IOException {
        String sql = compact(read(Path.of("legacy_migration/migrate_sales.sql")));

        for (String table : ITEM_TABLES) {
            assertThat(sql)
                    .contains("insert into " + table + " (")
                    .contains("goods_code_snapshot, goods_name_snapshot,"
                            + " goods_snapshot_source, goods_snapshot_locked_at");
        }
        assertThat(occurrences(sql, "'legacy_import'"))
                .isEqualTo(ITEM_TABLES.size() + 1); // V271 adds quotation snapshots.
    }

    private static String source(String relative) throws IOException {
        return compact(read(MAIN.resolve("java/com/uten/imp").resolve(relative)));
    }

    private static String read(Path path) throws IOException {
        return Files.readString(path, StandardCharsets.UTF_8);
    }

    private static String compact(String value) {
        return value.toLowerCase(Locale.ROOT).replaceAll("\\s+", " ").trim();
    }

    private static int occurrences(String value, String needle) {
        int count = 0;
        int from = 0;
        while ((from = value.indexOf(needle, from)) >= 0) {
            count++;
            from += needle.length();
        }
        return count;
    }
}
