package com.uten.imp.features.stock;

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

class StockGoodsHistorySnapshotContractTest {

    private static final Path MAIN = Path.of("src/main");
    private static final Path MIGRATION = MAIN.resolve(
            "resources/db/migration/V262__stock_goods_history_snapshots.sql");
    private static final List<String> AUTOMATED_WRITERS = List.of(
            "features/production/dailyreport/ProductionDailyReportService.java",
            "features/production/fulfillment/ProductionExecutionReadinessService.java",
            "features/production/fulfillment/ProductionPurchaseSupplyTransitionService.java",
            "features/production/mrp/MrpService.java",
            "features/production/mrp/ProductionExecutionPackageCommandService.java");
    private static final List<String> DIRECT_INSERT_FIXTURES = List.of(
            "features/production/execution/ProductionCompletionReversePostgresTest.java",
            "features/production/execution/ProductionExecutionSegmentOperationsPostgresTest.java",
            "features/production/fulfillment/ProductionMakeSupplyLifecyclePostgresTest.java",
            "features/production/fulfillment/ProductionPurchaseReceiptProvenancePostgresTest.java",
            "features/production/fulfillment/ProductionPurchaseSupplyTransitionPostgresTest.java",
            "features/production/mrp/ProductionExecutionSegmentPostgresTest.java",
            "features/sales/order/ExecutionSegmentSalesAllocationPostgresTest.java",
            "features/stock/ProductionLinkedStockDocumentGuardPostgresTest.java",
            "features/stock/ProductionMaterialAppendOnlyLedgerPostgresTest.java",
            "features/stock/ProductionMaterialIssueReturnPostgresTest.java");

    @Test
    void migrationBackfillsExplicitProvenanceWithoutChangingTheUuidRelation()
            throws IOException {
        String sql = compact(read(MIGRATION));

        assertThat(sql)
                .contains("alter table stock_document_items"
                        + " add column goods_code_snapshot text,"
                        + " add column goods_name_snapshot text,"
                        + " add column goods_snapshot_source text,"
                        + " add column goods_snapshot_locked_at timestamptz")
                .contains("update stock_document_items item"
                        + " set goods_code_snapshot = goods.code,")
                .contains("goods_snapshot_source = 'backfill_v262'")
                .contains("goods_snapshot_locked_at = case when document.status <> 0"
                        + " then now() else null end")
                .contains("set constraints all immediate")
                .contains("alter column goods_snapshot_source set not null")
                .contains("ck_stock_document_items_goods_snapshot_source")
                .contains("'legacy_import'", "'master_at_save'", "'master_at_approval'")
                .doesNotContain("alter column goods_id");
        assertThat(sql.indexOf("set constraints all immediate"))
                .isGreaterThan(sql.indexOf("update stock_document_items item"))
                .isLessThan(sql.indexOf(
                        "alter table stock_document_items alter column goods_snapshot_source"));
    }

    @Test
    void saveRefreshesAndApprovalLocksMasterSnapshotsBeforeInventoryMutation()
            throws IOException {
        String service = source("features/stock/StockDocService.java");

        assertThat(service)
                .contains("stockgoodssnapshot.master_at_save")
                .contains("stockgoodssnapshot.master_at_approval")
                .contains(".applyto(item, lockedat)")
                .contains("itemrepo.saveall(items)", "itemrepo.flush()");
        assertThat(service.indexOf(
                "capturegoodssnapshots( items, stockgoodssnapshot.master_at_approval"))
                .isLessThan(service.indexOf("lockinventory(items)"));
    }

    @Test
    void everyAutomatedDraftWriterCapturesTheGoodsMaster() throws IOException {
        int itemWriters = 0;
        for (String writer : AUTOMATED_WRITERS) {
            String source = source(writer);
            assertThat(source)
                    .contains("stockgoodssnapshot.master_at_save")
                    .contains(".applyto(");
            int constructors = occurrences(source, "new stockdocumentitem()");
            assertThat(occurrences(source, ".applyto(")).isEqualTo(constructors);
            itemWriters += constructors;
        }
        assertThat(itemWriters).isEqualTo(6);
    }

    @Test
    void stockSnapshotsNeverInferAuthorityFromPolymorphicUpstreamFields()
            throws IOException {
        String support = source("features/stock/StockGoodsSnapshot.java");

        assertThat(support)
                .contains("from goods")
                .doesNotContain("upstream_item_id")
                .doesNotContain("source_doc_no")
                .doesNotContain("coalesce(");
    }

    @Test
    void detailReportsProjectAndSearchHistoricalCodeAndName() throws IOException {
        String report = read(MAIN.resolve(
                "java/com/uten/imp/features/stock/report/StockReportService.java"));

        assertThat(occurrences(report, "goods_code_snapshot")).isEqualTo(8);
        assertThat(occurrences(report, "goods_name_snapshot")).isEqualTo(8);
        assertThat(report)
                .contains("COALESCE(i.goods_name_snapshot,'')")
                .contains("COALESCE(i.goods_code_snapshot,'')")
                .doesNotContain("\"g.code\"")
                .doesNotContain("\"g.name\"")
                .doesNotContain("gg.code")
                .doesNotContain("gg.name");
    }

    @Test
    void legacyImportAndDirectFixturesPopulateRequiredProvenance()
            throws IOException {
        String legacy = compact(read(Path.of("legacy_migration/migrate_stock_docs.sql")));
        assertThat(legacy)
                .contains("insert into stock_document_items (")
                .contains("goods_code_snapshot, goods_name_snapshot,"
                        + " goods_snapshot_source, goods_snapshot_locked_at")
                .contains("'legacy_import'");

        Pattern insert = Pattern.compile(
                "insert\\s+into\\s+stock_document_items\\s*\\((.*?)\\)\\s*values",
                Pattern.CASE_INSENSITIVE | Pattern.DOTALL);
        int inserts = 0;
        for (String fixture : DIRECT_INSERT_FIXTURES) {
            String java = read(Path.of("src/test/java/com/uten/imp").resolve(fixture));
            Matcher matcher = insert.matcher(java);
            while (matcher.find()) {
                inserts++;
                assertThat(matcher.group(1))
                        .containsIgnoringCase("goods_snapshot_source");
            }
        }
        assertThat(inserts).isEqualTo(13);
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
