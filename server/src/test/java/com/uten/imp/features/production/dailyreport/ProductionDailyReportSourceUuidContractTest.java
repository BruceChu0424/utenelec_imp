package com.uten.imp.features.production.dailyreport;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionDailyReportSourceUuidContractTest {

    @Test
    void v275AddsUuidForeignKeysWithoutGuessingHistoricalNumbers() throws IOException {
        String sql = canonical(source(
                "src/main/resources/db/migration/"
                        + "V275__production_daily_report_source_uuid_guards.sql"));

        assertThat(sql)
                .contains("FOREIGN KEY (plan_item_id) REFERENCES production_plan_items(id)")
                .contains("FOREIGN KEY (sales_order_item_id) REFERENCES sales_order_items(id)")
                .contains("ON DELETE RESTRICT NOT VALID")
                .contains("VALIDATE CONSTRAINT fk_pdri_plan_item")
                .contains("VALIDATE CONSTRAINT fk_pdri_sales_order_item")
                .contains("ADD CONSTRAINT ck_pdri_number_snapshots_require_uuid")
                .contains("CHECK (")
                .contains(") NOT VALID")
                .doesNotContain("UPDATE production_daily_report_items")
                .doesNotContain("JOIN production_plans plan ON plan.bill_no")
                .doesNotContain("JOIN sales_orders sales_order ON sales_order.bill_no");
    }

    @Test
    void runtimeNeverResolvesPlanIdentityFromNumberSnapshot() throws IOException {
        String service = source(
                "src/main/java/com/uten/imp/features/production/dailyreport/"
                        + "ProductionDailyReportService.java");

        assertThat(service)
                .contains("private UUID resolvePlanItem(ProductionDailyReportItem it)")
                .contains("if (it.getPlanItemId() != null)")
                .contains("报工来源只有编号快照，不能自动猜关联")
                .doesNotContain("WHERE p.bill_no = :no")
                .doesNotContain("setParameter(\"no\", planNo)")
                .doesNotContain("UPDATE production_daily_report_items SET plan_item_id");
    }

    @Test
    void saveDerivesReadableSnapshotsFromUuidRelations() throws IOException {
        String service = source(
                "src/main/java/com/uten/imp/features/production/dailyreport/"
                        + "ProductionDailyReportService.java");

        assertThat(service)
                .contains("canonicalizeSourceSnapshots(lines);")
                .contains("JOIN production_plans plan ON plan.id = item.plan_id")
                .contains("JOIN sales_orders sales_order ON sales_order.id = item.order_id")
                .contains("line.setPlanNo(planNos.get(line.getPlanItemId()))")
                .contains("line.setSalesOrderNo(orderNos.get(line.getSalesOrderItemId()))")
                .contains("计划号不能单独建立关联")
                .contains("销售订单号不能单独建立关联");
    }

    @Test
    void flutterRequiresExplicitRelinkOrClearForLegacyNumberOnlyRows() throws IOException {
        String page = source(
                "../lib/features/production/pages/production_daily_report_edit_page.dart");
        String row = source(
                "../lib/features/production/widgets/production_daily_grid_columns.dart");

        assertThat(page)
                .contains("r.planItemId == null && r.planNo.text.trim().isNotEmpty")
                .contains("请重新选择来源子任务或清除来源")
                .contains("r.salesOrderItemId == null")
                .contains("旧报工行只有销售订单号快照");
        assertThat(row)
                .contains("bool get hasSourceSnapshot")
                .contains("row.hasLinkedSource || row.hasSourceSnapshot");
    }

    private static String source(String serverRelativePath) throws IOException {
        Path direct = Path.of(serverRelativePath);
        Path path = Files.exists(direct) ? direct : Path.of("server").resolve(serverRelativePath);
        return Files.readString(path.normalize(), StandardCharsets.UTF_8);
    }

    private static String canonical(String value) {
        return value.replaceAll("\\s+", " ").trim();
    }
}
