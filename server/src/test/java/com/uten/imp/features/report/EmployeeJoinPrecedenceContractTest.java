package com.uten.imp.features.report;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

class EmployeeJoinPrecedenceContractTest {

    private static final Path REPORT_ROOT = Path.of(
            "src/main/java/com/uten/imp/features");

    private static final Pattern LEGACY_FIRST_OR_JOIN = Pattern.compile(
            "LEFT JOIN employees\\s+\\w+\\s+ON\\s+"
                    + "\\w+\\.legacy_id\\s*=.*?\\s+OR\\s+"
                    + "\\w+\\.id\\s*=",
            Pattern.CASE_INSENSITIVE | Pattern.MULTILINE);

    @Test
    void uuidCapableReportEmployeeJoinsUseUuidBeforeLegacyFallback()
            throws Exception {
        String purchase = source(
                "purchase/report/PurchaseReportService.java");
        assertJoin(purchase, "em_app", "o.applicant_id",
                "o.applicant_legacy_id", 2);
        assertUuidOnlyJoin(purchase, "em_mk", "o.maker_id", 4);
        assertUuidOnlyJoin(purchase, "em_ap", "o.approver_id", 2);
        assertThat(purchase).doesNotContain("em_mk.legacy_id", "em_ap.legacy_id");
        assertThat(purchase).contains("COALESCE(em_mk.full_name, o.maker_name)",
                "COALESCE(em_ap.full_name, o.approver_name)");
        assertJoin(purchase, "em_pur", "o.purchaser_id",
                "o.purchaser_legacy_id", 2);
        assertJoin(purchase, "em_pur", "po.purchaser_id",
                "po.purchaser_legacy_id", 1);
        assertJoin(purchase, "em_rec", "o.receiver_id",
                "o.receiver_legacy_id", 2);

        String stock = source("stock/report/StockReportService.java");
        assertJoin(stock, "em_wk", "o.worker_id",
                "o.worker_legacy_id", 2);
        assertUuidOnlyJoin(stock, "em_mk", "o.maker_id", 2);
        assertUuidOnlyJoin(stock, "em_ap", "o.approver_id", 2);
        assertThat(stock).doesNotContain("em_mk.legacy_id", "em_ap.legacy_id");
        assertThat(stock).contains("o.maker_name_snapshot",
                "o.approver_name_snapshot");

        String sales = source("sales/report/SalesReportService.java");
        assertJoin(sales, "em_sel", "o.seller_id",
                "o.seller_legacy_id", 1);
        assertJoin(sales, "em_snd", "o.sender_id",
                "o.sender_legacy_id", 1);

        String finance = source(
                "finance/report/FinanceReportService.java");
        assertJoin(finance, "em_op", "t.operator_id",
                "t.operator_legacy_id", 7);
        assertUuidOnlyJoin(finance, "em_mk", "t.maker_id", 3);
        assertUuidOnlyJoin(finance, "em_ap", "t.approver_id", 3);
        assertThat(finance).doesNotContain("em_mk.legacy_id", "em_ap.legacy_id");
        assertThat(finance).contains("COALESCE(em_mk.full_name, t.maker_name,'')",
                "COALESCE(em_ap.full_name, t.approver_name,'')");

        String subcontract = source(
                "subcontract/report/SubcontractReportService.java");
        assertJoin(subcontract, "em_rec", "o.sender_id",
                "o.receiver_legacy_id", 2);
        assertJoin(subcontract, "em_op", "o.worker_id",
                "o.operator_legacy_id", 4);

        String production = source(
                "production/report/ProductionReportService.java");
        assertUuidOnlyJoin(production, "em_mk", "p.maker_id", 1);
        assertUuidOnlyJoin(production, "em_ap", "p.approver_id", 1);
        assertThat(production).doesNotContain("em_mk.legacy_id", "em_ap.legacy_id");
        assertThat(production).contains("COALESCE(em_mk.full_name, p.maker_name)",
                "COALESCE(em_ap.full_name, p.approver_name)");

        for (String report : List.of(
                purchase, stock, sales, finance, subcontract, production)) {
            assertThat(LEGACY_FIRST_OR_JOIN.matcher(report).find())
                    .as("legacy-first OR join can duplicate report rows")
                    .isFalse();
        }
    }

    private static String source(String relativePath) throws IOException {
        return canonical(Files.readString(REPORT_ROOT.resolve(relativePath)));
    }

    private static void assertJoin(
            String source,
            String alias,
            String currentId,
            String legacyId,
            int expectedCount) {
        String clause = "LEFT JOIN employees " + alias
                + " ON " + alias + ".id=" + currentId
                + " OR (" + currentId + " IS NULL AND "
                + alias + ".legacy_id=" + legacyId + ")";
        assertThat(occurrences(source, clause))
                .as("UUID-first employee join: %s", clause)
                .isEqualTo(expectedCount);
    }

    private static void assertUuidOnlyJoin(
            String source,
            String alias,
            String currentId,
            int expectedCount) {
        String clause = "LEFT JOIN employees " + alias
                + " ON " + alias + ".id=" + currentId;
        assertThat(occurrences(source, clause))
                .as("UUID-only employee join: %s", clause)
                .isEqualTo(expectedCount);
    }

    private static int occurrences(String source, String clause) {
        int count = 0;
        int from = 0;
        while ((from = source.indexOf(clause, from)) >= 0) {
            count++;
            from += clause.length();
        }
        return count;
    }

    private static String canonical(String source) {
        return source.replaceAll("\\s+", " ")
                .replaceAll("\\s*=\\s*", "=")
                .trim();
    }
}
