package com.uten.imp.features.subcontract;

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

class SubcontractGoodsHistorySnapshotContractTest {

    private static final Path MAIN = Path.of("src/main");
    private static final Path MIGRATION = MAIN.resolve(
            "resources/db/migration/V263__subcontract_goods_history_snapshots.sql");
    private static final List<String> ITEM_TABLES = List.of(
            "subcontract_inquiry_items",
            "subcontract_application_items",
            "subcontract_order_items",
            "subcontract_receipt_items",
            "subcontract_material_issue_items",
            "subcontract_return_items",
            "subcontract_material_return_items",
            "subcontract_waste_items",
            "subcontract_order_cost_items");

    @Test
    void migrationBackfillsNineChildIdentitiesAndThreeSeparateParentIdentities()
            throws IOException {
        String sql = compact(read(MIGRATION));
        for (String table : ITEM_TABLES) {
            assertThat(sql)
                    .contains("alter table " + table)
                    .contains("update " + table + " item")
                    .contains("'" + table + "'");
        }
        assertThat(sql).contains("'ck_' || table_name || '_goods_snapshot_source'");
        assertThat(occurrences(sql, "goods_snapshot_source = 'backfill_v263'"))
                .isEqualTo(ITEM_TABLES.size() + 3);
        assertThat(occurrences(sql, "parent_goods_snapshot_source = 'backfill_v263'"))
                .isEqualTo(3);
        assertThat(sql)
                .contains("drop materialized view if exists subcontract_monthly_mv")
                .contains("item.goods_code_snapshot, item.goods_name_snapshot")
                .contains("create unique index mv_subcontract_monthly_uidx")
                .contains("goods_code_snapshot, goods_name_snapshot, supplier_id, currency_id) nulls not distinct")
                .doesNotContain("coalesce(goods_code_snapshot, '')")
                .doesNotContain("alter column goods_id")
                .doesNotContain("alter column parent_goods_id")
                .doesNotContain("alter column order_item_id");
    }

    @Test
    void saveAndApprovalPathsCaptureNearestUpstreamAndLockBeforeEffects()
            throws IOException {
        String inquiry = source("features/subcontract/inquiry/SubcontractInquiryService.java");
        String application = source("features/subcontract/application/SubcontractApplicationService.java");
        String order = source("features/subcontract/order/SubcontractOrderService.java");
        String receipt = source("features/subcontract/receipt/SubcontractReceiptService.java");
        String issue = source("features/subcontract/material_issue/SubcontractMaterialIssueService.java");
        String finishedReturn = source("features/subcontract/ret/SubcontractReturnService.java");
        String materialReturn = source("features/subcontract/material_return/SubcontractMaterialReturnService.java");
        String waste = source("features/subcontract/waste/SubcontractWasteService.java");
        String automatedApplication = source(
                "features/subcontract/application/ProductionSubcontractRequestFacade.java");

        assertThat(inquiry).contains("master_at_save", "master_at_approval", "setgoodssnapshotlockedat");
        assertThat(application).contains("master_at_save", "master_at_approval", "setgoodssnapshotlockedat");
        assertThat(order).contains("application_item_at_save", "application_item_at_approval");
        assertThat(receipt).contains("order_item_at_save", "order_item_at_approval");
        assertThat(finishedReturn).contains("receipt_item_at_save", "receipt_item_at_approval");
        assertThat(issue).contains("applychildsnapshot", "applyparentsnapshot", "order_item_at_approval");
        assertThat(materialReturn).contains(
                "material_issue_item_at_save", "material_issue_item_at_approval",
                "applychildsnapshot", "applyparentsnapshot");
        assertThat(waste).contains("material_issue_item_at_save", "material_issue_item_at_approval");
        assertThat(automatedApplication)
                .contains("master_at_approval")
                .contains("setgoodssnapshotlockedat(snapshotlockedat)");

        assertThat(receipt.indexOf("capturegoodssnapshots("))
                .isLessThan(receipt.indexOf("inspectionservice.receive("));
        assertThat(finishedReturn.indexOf("capturegoodssnapshots("))
                .isLessThan(finishedReturn.indexOf("stockservice.lockinventory("));
        assertThat(issue.indexOf("capturegoodssnapshots("))
                .isLessThan(issue.indexOf("stockservice.lockinventory("));
        assertThat(materialReturn.indexOf("capturegoodssnapshots("))
                .isLessThan(materialReturn.indexOf("stockservice.lockinventory("));
        assertThat(waste.indexOf("capturegoodssnapshots("))
                .isLessThan(waste.indexOf("update subcontract_material_issue_items"));
    }

    @Test
    void dtoReportsKeywordAndInOutUseFrozenIdentityEra() throws IOException {
        String report = source("features/subcontract/report/SubcontractReportService.java");
        String keyword = source("features/subcontract/SubcontractGoodsKeyword.java");
        String snapshot = source("features/subcontract/SubcontractGoodsSnapshot.java");

        assertThat(report)
                .contains("i.goods_code_snapshot as \"goodscode\"")
                .contains("i.goods_name_snapshot as \"goodsname\"")
                .contains("a.goods_code_snapshot as goodscode")
                .contains("group by supplier_id, goods_id, goods_code_snapshot, goods_name_snapshot, color_id")
                .contains("od.goods_code_snapshot is not distinct from a.goods_code_snapshot")
                .doesNotContain("g.code as \"goodscode\"")
                .doesNotContain("g.name as \"goodsname\"");
        assertThat(keyword)
                .contains("goodsnamesnapshot")
                .contains("goodscodesnapshot")
                .contains("cb.exists(itemmatch)");
        assertThat(snapshot)
                .contains("item.goods_code_snapshot, item.goods_name_snapshot")
                .contains("item.parent_goods_code_snapshot")
                .doesNotContain("coalesce(item.goods_code_snapshot, goods.code)")
                .doesNotContain("coalesce(item.goods_name_snapshot, goods.name)");

        for (String dto : List.of(
                "inquiry/dto/InquiryItemDto.java",
                "application/dto/ApplicationItemDto.java",
                "order/dto/OrderItemDto.java",
                "receipt/dto/ReceiptItemDto.java",
                "material_issue/dto/MaterialIssueItemDto.java",
                "ret/dto/ReturnItemDto.java",
                "material_return/dto/MaterialReturnItemDto.java",
                "waste/dto/WasteItemDto.java")) {
            assertThat(source("features/subcontract/" + dto))
                    .contains("goodscodesnapshot", "goodsnamesnapshot", "goodssnapshotsource");
        }
    }

    @Test
    void legacyAndDirectInsertWritersProvideRequiredProvenance() throws IOException {
        String legacy = compact(read(Path.of("legacy_migration/migrate_subcontract.sql")));
        for (String table : List.of(
                "subcontract_order_items",
                "subcontract_order_cost_items",
                "subcontract_material_issue_items",
                "subcontract_receipt_items",
                "subcontract_return_items",
                "subcontract_material_return_items",
                "subcontract_waste_items")) {
            assertThat(legacy)
                    .contains("insert into " + table + " (")
                    .contains("goods_code_snapshot, goods_name_snapshot, goods_snapshot_source, goods_snapshot_locked_at");
        }
        assertThat(occurrences(legacy, "'legacy_import'"))
                .isGreaterThanOrEqualTo(10);

        Pattern directInsert = Pattern.compile(
                "insert\\s+into\\s+subcontract_(?:inquiry|application|order|receipt|material_issue|return|material_return|waste|order_cost)_items\\s*\\((.*?)\\)\\s*values",
                Pattern.CASE_INSENSITIVE | Pattern.DOTALL);
        int found = 0;
        for (Path fixture : List.of(
                Path.of("src/test/java/com/uten/imp/features/production/analysis/PreplanExternalSupplySourceGuardPostgresTest.java"),
                Path.of("src/test/java/com/uten/imp/features/subcontract/material_issue/SubcontractMaterialConservationPostgresTest.java"))) {
            Matcher matcher = directInsert.matcher(read(fixture));
            while (matcher.find()) {
                found++;
                assertThat(matcher.group(1)).containsIgnoringCase("goods_snapshot_source");
            }
        }
        assertThat(found).isEqualTo(3);
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
