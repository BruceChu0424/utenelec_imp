package com.uten.imp.features.purchase;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
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
    private static final Map<String, List<String>> DIRECT_INSERT_FIXTURES = Map.of(
            "features/operations/workbench/FulfillmentWorkbenchProvisionalStockPostgresTest.java", List.of(
                    "purchase_request_items:select", "purchase_order_items:values",
                    "purchase_request_items:select", "purchase_request_items:values"),
            "features/production/analysis/PreplanExternalSupplySourceGuardPostgresTest.java", List.of(
                    "purchase_request_items:values", "purchase_order_items:values",
                    "purchase_receipt_items:values", "purchase_request_items:values"),
            "features/production/fulfillment/ProductionPurchaseReceiptProvenancePostgresTest.java", List.of(
                    "purchase_order_items:values", "purchase_receipt_items:values"),
            "features/production/fulfillment/ProductionPurchaseSupplyTransitionPostgresTest.java", List.of(
                    "purchase_request_items:values", "purchase_order_items:values", "purchase_receipt_items:values"),
            "features/production/mrp/ProductionExecutionSegmentPostgresTest.java", List.of(
                    "purchase_request_items:values", "purchase_order_items:values", "purchase_receipt_items:values"),
            "features/production/mrp/ProductionMaterialFulfillmentPostgresTest.java", List.of(
                    "purchase_request_items:values", "purchase_order_items:values"),
            "features/warehouse/inbound/ProcurementArrivalGuardPostgresTest.java", List.of(
                    "purchase_receipt_items:values", "purchase_receipt_items:values", "purchase_order_items:values"));
    private static final Pattern DIRECT_ITEM_INSERT = Pattern.compile(
            "insert\\s+into\\s+(purchase_(?:request|order|receipt|return)_items)\\s*\\(([^)]*)\\)\\s*(values|select)",
            Pattern.CASE_INSENSITIVE | Pattern.DOTALL);

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
        // ADR-109：MRP「按计划一键生成采购申请」入口已删除，系统生成采购申请只剩上面这一个写入口；
        // MrpService 不能再自己写采购申请明细(否则会绕开快照)。
        assertThat(mrp)
                .doesNotContain("purchaserequestitem")
                .doesNotContain("purchasegoodssnapshot");
    }

    @Test
    void detailReportsProjectAndSearchHistoricalCodeAndName() throws IOException {
        String report = read(MAIN.resolve(
                "java/com/uten/imp/features/purchase/report/PurchaseReportService.java"));

        // 2026-09-14：又有一处报表投影从 g.code 改成 i.goods_code_snapshot（方向与
        // 本契约一致——历史单据一律读快照），计数 5 → 6。
        // 2026-09-16：ReportQueryKit 抽取把共享的关键字搜索片段（含快照 COALESCE）
        // 搬进 common/report，服务内计数 6 → 5，搬走的那份由 kit 侧断言守卫。
        assertThat(occurrences(report, "goods_code_snapshot"))
                .isEqualTo(5);
        assertThat(occurrences(report, "goods_name_snapshot"))
                .isEqualTo(5);
        assertThat(report)
                .doesNotContain("g.code AS \"goodsCode\"")
                .doesNotContain("g.name AS \"goodsName\"")
                .doesNotContain("gg.name")
                .doesNotContain("gg.code");
        String kit = read(MAIN.resolve(
                "java/com/uten/imp/common/report/ReportQueryKit.java"));
        assertThat(kit)
                .contains("w.search(kw, parameter ->")
                .contains("i.goods_name_snapshot ILIKE")
                .contains("i.goods_code_snapshot ILIKE")
                .contains("billNoCol, \"i.goods_name_snapshot\", \"i.goods_code_snapshot\"")
                .doesNotContain("gg.name", "gg.code");
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
        // V626/V627 重写后口径：申请/订货/退货三张 *_items 仍由 loader 写死 'LEGACY_IMPORT'；
        // 收货明细（第 4 张）的商业字段与 goods_snapshot_source 改由 V627 权威来源投影
        // fn_legacy_receipt_source_projection 给出（其中固化 'LEGACY_IMPORT'），loader 只
        // 注册来源证明并引用 projected.*，故脚本内字面量 4 → 3。
        assertThat(occurrences(legacy, "'legacy_import'"))
                .isEqualTo(ITEM_TABLES.size() - 1);
        assertThat(legacy)
                .contains("fn_register_legacy_receipt_import_source(")
                .contains("fn_legacy_receipt_source_projection('purchase_item'")
                .contains("projected.goods_snapshot_source");
        assertThat(compact(read(MAIN.resolve(
                "resources/db/migration/V627__legacy_receipt_consideration_provenance.sql"))))
                .contains("'goods_snapshot_source','legacy_import'");

        for (var fixture : DIRECT_INSERT_FIXTURES.entrySet()) {
            String java = read(Path.of("src/test/java/com/uten/imp").resolve(fixture.getKey()));
            Matcher matcher = DIRECT_ITEM_INSERT.matcher(java);
            List<String> writers = new ArrayList<>();
            while (matcher.find()) {
                writers.add(matcher.group(1).toLowerCase(Locale.ROOT) + ":"
                        + matcher.group(3).toLowerCase(Locale.ROOT));
                assertThat(matcher.group(2)).as(fixture.getKey() + " " + matcher.group(1))
                        .containsIgnoringCase("goods_snapshot_source");
            }
            assertThat(writers).as(fixture.getKey() + " direct writer inventory")
                    .containsExactlyElementsOf(fixture.getValue());
        }
    }

    @Test
    void directInsertMatcherKeepsSelectColumnsSeparateFromLaterValues() {
        Matcher matcher = DIRECT_ITEM_INSERT.matcher("""
                INSERT INTO purchase_request_items(id,goods_snapshot_source)
                SELECT source.id,'MASTER_AT_SAVE' FROM source;
                INSERT INTO unrelated_table(id) VALUES ('later');
                INSERT INTO purchase_order_items(id,goods_snapshot_source)
                VALUES ('order','MASTER_AT_SAVE');
                """);
        assertThat(matcher.find()).isTrue();
        assertThat(matcher.group(1)).isEqualTo("purchase_request_items");
        assertThat(matcher.group(2)).isEqualTo("id,goods_snapshot_source");
        assertThat(matcher.group(3)).isEqualToIgnoringCase("SELECT");
        assertThat(matcher.find()).isTrue();
        assertThat(matcher.group(1)).isEqualTo("purchase_order_items");
        assertThat(matcher.group(2)).isEqualTo("id,goods_snapshot_source");
        assertThat(matcher.group(3)).isEqualToIgnoringCase("VALUES");
        assertThat(matcher.find()).isFalse();
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
