package com.uten.imp.features.documents;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 报表默认口径契约（G5-reports）：销售/采购/委外/仓库/钱流报表在调用方未显式传 status 时
 * 默认排除草稿（{@code status <> 0}），显式传 status（含查草稿）时仍按调用方口径走。
 *
 * <p>不再允许各报表把「审核状态」当纯可选筛选——那会让未审核单据默认进明细/汇总。
 *
 * <p>2026-09-16 收敛：sales/purchase/subcontract/stock（单头别名 {@code o}）的
 * {@code addApprovedByDefault} 收敛到 {@code common/report/ReportQueryKit}，四服务调用共享入口；
 * finance（钱流单头别名 {@code t}）逻辑相同但别名不同，保留本地实现，本测试分别断言。
 */
class ReportDraftExclusionContractTest {

    /** 报表服务 → 单头别名。 */
    private static final Map<String, String> SERVICES = Map.of(
            "sales/report/SalesReportService.java", "o",
            "purchase/report/PurchaseReportService.java", "o",
            "subcontract/report/SubcontractReportService.java", "o",
            "stock/report/StockReportService.java", "o",
            "finance/report/FinanceReportService.java", "t");

    private static final String KIT = "common/report/ReportQueryKit.java";

    @Test
    void everyReportServiceDefaultsToExcludingDraftsAndKeepsExplicitStatusQueryable() throws Exception {
        // 收敛后的统一入口：o 别名四服务共用 ReportQueryKit.addApprovedByDefault。
        String kit = Files.readString(
                Path.of("src/main/java/com/uten/imp/" + KIT), StandardCharsets.UTF_8);
        assertThat(kit)
                .as("%s 必须有默认排除草稿的统一入口", KIT)
                .contains("public static void addApprovedByDefault(WhereBuilder w, Short status)")
                .contains("w.add(\"o.status <> 0\", null, null)");
        // 显式 status 仍然生效（可查草稿）；空格差异归一后比较。
        assertThat(kit.replace(" ", ""))
                .as("%s 显式 status 仍要能查（含 status=0 查草稿）", KIT)
                .contains("w.add(\"o.status=:status\",\"status\",status);");

        for (Map.Entry<String, String> entry : SERVICES.entrySet()) {
            String source = read(entry.getKey());
            String alias = entry.getValue();

            if ("t".equals(alias)) {
                // finance 单头别名是 t：保留本地实现，原断言口径不变。
                assertThat(source)
                        .as("%s 必须有默认排除草稿的统一入口", entry.getKey())
                        .contains("private static void addApprovedByDefault(WhereBuilder w, Short status)")
                        .contains("w.add(\"" + alias + ".status <> 0\", null, null)");
                assertThat(source.replace(" ", ""))
                        .as("%s 显式 status 仍要能查（含 status=0 查草稿）", entry.getKey())
                        .contains("w.add(\"" + alias + ".status=:status\",\"status\",status);");
            } else {
                // o 别名四服务：必须经由共享入口，不得自带分叉实现。
                assertThat(source)
                        .as("%s 必须走 ReportQueryKit 的默认排除草稿入口", entry.getKey())
                        .contains("ReportQueryKit.addApprovedByDefault(w, status)");
            }
        }
    }

    /** 默认口径不能绕过：公共过滤方法里不得再留裸的 {@code if (status != null)} 分支。 */
    @Test
    void noReportServiceStillTreatsStatusAsAPurelyOptionalFilter() throws Exception {
        for (Map.Entry<String, String> entry : SERVICES.entrySet()) {
            String source = read(entry.getKey());
            String alias = entry.getValue();

            assertThat(source)
                    .as("%s 仍有把 status 当纯可选筛选的分支", entry.getKey())
                    .doesNotContain("if (status != null) w.add(\"" + alias + ".status = :status\"")
                    .doesNotContain("if (status != null) w.add(\"" + alias + ".status=:status\"");
        }
    }

    /**
     * V551：待交货订货汇总视图只保留已审订单，且只改这一条谓词（列名/列序/聚合口径不动，
     * 否则 CREATE OR REPLACE 会失败）。
     */
    @Test
    void pendingDeliveryViewKeepsOnlyApprovedOrders() throws Exception {
        String migration = Files.readString(Path.of(
                "src/main/resources/db/migration/"
                        + "V551__sales_order_pending_view_excludes_drafts.sql"),
                StandardCharsets.UTF_8);

        assertThat(migration).contains("CREATE OR REPLACE VIEW sales_order_pending_v AS");
        assertThat(migration).contains(
                "WHERE i.is_deleted = false AND o.is_deleted = false AND o.status = 1");
        for (String column : List.of("i.goods_id", "i.color_id", "o.client_id",
                "AS pending_qty", "AS pending_amt")) {
            assertThat(migration)
                    .as("V551 不得改动 sales_order_pending_v 的列：%s", column)
                    .contains(column);
        }
        assertThat(migration).contains("GROUP BY i.goods_id, i.color_id, o.client_id");
        assertThat(migration).contains("COMMENT ON VIEW sales_order_pending_v IS");
        // 自包含：不得依赖别的迁移先建视图。
        assertThat(migration).doesNotContain("DROP VIEW");
    }

    private static String read(String relative) throws Exception {
        return Files.readString(
                Path.of("src/main/java/com/uten/imp/features/" + relative),
                StandardCharsets.UTF_8);
    }
}
