package com.uten.imp.features.purchase;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

class PurchaseGoodsHistorySnapshotContractTest {

    private static final Path MAIN = Path.of("src/main");
    private static final Path MIGRATION = MAIN.resolve(
            "resources/db/migration/V260__purchase_goods_history_snapshots.sql");
    private static final List<String> ITEM_TABLES = List.of(
            "purchase_request_items",
            "purchase_order_items",
            "purchase_receipt_items",
            "purchase_return_items");
    private static final List<String> DIRECT_INSERT_FIXTURES = List.of(
            "features/operations/workbench/FulfillmentWorkbenchProvisionalStockPostgresTest.java",
            "features/production/analysis/PreplanExternalSupplySourceGuardPostgresTest.java",
            "features/production/fulfillment/ProductionPurchaseReceiptProvenancePostgresTest.java",
            "features/production/fulfillment/ProductionPurchaseSupplyTransitionPostgresTest.java",
            "features/production/mrp/ProductionExecutionSegmentPostgresTest.java",
            "features/production/mrp/ProductionMaterialFulfillmentPostgresTest.java",
            "features/warehouse/inbound/ProcurementArrivalGuardPostgresTest.java");

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
                    .contains("update " + table
                            + " item set goods_code_snapshot = goods.code,")
                    .contains("alter table " + table
                            + " alter column goods_snapshot_source set not null,")
                    .contains("ck_" + table + "_goods_snapshot_source");
        }

        assertThat(occurrences(sql, "goods_snapshot_source = 'backfill_v260'"))
                .isEqualTo(ITEM_TABLES.size());
        assertThat(occurrences(
                sql,
                "goods_snapshot_locked_at = case when document.status <> 0 then now() else null end"))
                .isEqualTo(ITEM_TABLES.size());
        assertThat(occurrences(sql, "set constraints all immediate"))
                .isEqualTo(1);
        assertThat(sql.indexOf("set constraints all immediate"))
                .isGreaterThan(sql.lastIndexOf("update purchase_return_items item"))
                .isLessThan(sql.indexOf(
                        "alter table purchase_request_items alter column goods_snapshot_source"));
        assertThat(sql)
                .contains("'legacy_import'", "'master_at_save'", "'master_at_approval'",
                        "'request_item_at_save'", "'request_item_at_approval'",
                        "'order_item_at_save'", "'order_item_at_approval'",
                        "'receipt_item_at_save'", "'receipt_item_at_approval'")
                .doesNotContain("alter column goods_id");
    }

    @Test
    void saveAndApprovalPathsUseTheNearestAuthoritativeSnapshot() throws IOException {
        String request = source("features/purchase/request/PurchaseRequestService.java");
        String order = source("features/purchase/order/PurchaseOrderService.java");
        String receipt = source("features/purchase/receipt/PurchaseReceiptService.java");
        String purchaseReturn = source("features/purchase/ret/PurchaseReturnService.java");

        assertThat(request)
                .contains("purchasegoodssnapshot.master_at_save")
                .contains("purchasegoodssnapshot.master_at_approval")
                .contains("setgoodssnapshotlockedat(lockedat)");
        assertThat(order)
                .contains("purchasegoodssnapshot.request_item_at_save")
                .contains("purchasegoodssnapshot.request_item_at_approval")
                .contains("purchasegoodssnapshot.master_at_save")
                .contains("purchasegoodssnapshot.master_at_approval");
        assertThat(receipt)
                .contains("purchasegoodssnapshot.order_item_at_save")
                .contains("purchasegoodssnapshot.order_item_at_approval")
                .contains("purchasegoodssnapshot.master_at_save")
                .contains("purchasegoodssnapshot.master_at_approval");
        assertThat(purchaseReturn)
                .contains("purchasegoodssnapshot.receipt_item_at_save")
                .contains("purchasegoodssnapshot.receipt_item_at_approval")
                .contains("purchasegoodssnapshot.order_item_at_save")
                .contains("purchasegoodssnapshot.order_item_at_approval")
                .contains("purchasegoodssnapshot.master_at_save")
                .contains("purchasegoodssnapshot.master_at_approval");

        assertThat(order.indexOf("capturegoodssnapshots("))
                .isLessThan(order.indexOf("productionsupply.onpurchaseorderapproved(id)"));
        assertThat(receipt.indexOf(
                "capturegoodssnapshots( items, purchasegoodssnapshot.order_item_at_approval"))
                .isLessThan(receipt.indexOf("inspectionservice.receive("));
        assertThat(purchaseReturn.indexOf(
                "capturegoodssnapshots( items, purchasegoodssnapshot.receipt_item_at_approval"))
                .isLessThan(purchaseReturn.indexOf("applymovement(r, it, stockservice.dir_out"));
    }

    @Test
    void automatedPurchaseRequestWritersAlsoPopulateRequiredSnapshots() throws IOException {
        String facade = source(
                "features/purchase/request/ProductionPurchaseRequestFacade.java");
        String mrp = source("features/production/mrp/MrpService.java");

        assertThat(facade)
                .contains("purchasegoodssnapshot.master_at_approval")
                .contains("item.setgoodssnapshotlockedat(snapshotlockedat)");
        assertThat(mrp)
                .contains("purchasegoodssnapshot.master_at_save")
                .contains("it.setgoodssnapshotsource(goodssnapshot.source())");
    }

    @Test
    void detailReportsProjectAndSearchHistoricalCodeAndName() throws IOException {
        String report = read(MAIN.resolve(
                "java/com/uten/imp/features/purchase/report/PurchaseReportService.java"));

        assertThat(occurrences(report, "goods_code_snapshot"))
                .isEqualTo(5);
        assertThat(occurrences(report, "goods_name_snapshot"))
                .isEqualTo(6);
        assertThat(report)
                .contains("COALESCE(i.goods_name_snapshot,'')")
                .contains("COALESCE(i.goods_code_snapshot,'')")
                .doesNotContain("g.code AS \"goodsCode\"")
                .doesNotContain("g.name AS \"goodsName\"")
                .doesNotContain("gg.name")
                .doesNotContain("gg.code");
    }

    @Test
    void downstreamSnapshotsNeverCoalesceToRenamedMasterLabels() throws IOException {
        String support = source("features/purchase/PurchaseGoodsSnapshot.java");

        assertThat(support)
                .contains("from purchase_request_items item")
                .contains("from purchase_order_items item")
                .contains("from purchase_receipt_items item")
                .contains("item.goods_code_snapshot, item.goods_name_snapshot")
                .doesNotContain("coalesce(item.goods_code_snapshot, goods.code)")
                .doesNotContain("coalesce(item.goods_name_snapshot, goods.name)");
    }

    @Test
    void legacyImportAndDirectFixturesPopulateRequiredProvenance() throws IOException {
        String legacy = compact(read(Path.of("legacy_migration/migrate_purchase.sql")));
        for (String table : ITEM_TABLES) {
            assertThat(legacy)
                    .contains("insert into " + table + " (")
                    .contains("goods_code_snapshot, goods_name_snapshot,"
                            + " goods_snapshot_source, goods_snapshot_locked_at");
        }
        assertThat(occurrences(legacy, "'legacy_import'"))
                .isEqualTo(ITEM_TABLES.size());

        Pattern insert = Pattern.compile(
                "insert\\s+into\\s+purchase_(?:request|order|receipt|return)_items\\s*\\((.*?)\\)\\s*values",
                Pattern.CASE_INSENSITIVE | Pattern.DOTALL);
        int inserts = 0;
        for (String fixture : DIRECT_INSERT_FIXTURES) {
            String java = read(Path.of("src/test/java/com/uten/imp").resolve(fixture));
            Matcher matcher = insert.matcher(java);
            while (matcher.find()) {
                inserts++;
                assertThat(matcher.group(1)).containsIgnoringCase("goods_snapshot_source");
            }
        }
        assertThat(inserts).isEqualTo(15);
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
