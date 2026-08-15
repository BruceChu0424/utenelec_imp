package com.uten.imp.features.report;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class MasterReferenceJoinPrecedenceContractTest {

    private static final Path FEATURE_ROOT = Path.of(
            "src/main/java/com/uten/imp/features");

    @Test
    void onlineWritersRequireCanonicalUuidRelationshipsWithoutLegacyLookup()
            throws Exception {
        String mrp = source("production/mrp/MrpService.java");
        assertStrictColorJoin(mrp, 3);
        assertStrictUnitJoin(mrp, "u", "g.unit_id", 1);

        String execution = source(
                "production/mrp/ProductionExecutionPlanningService.java");
        assertStrictColorJoin(execution, 1);
        assertStrictUnitJoin(
                execution, "component_unit", "component.unit_id", 1);

        assertStrictUnitJoin(
                source("stock/StockDocService.java"), "u", "g.unit_id", 1);
    }

    @Test
    void readOnlyHistoricalProjectionsMayRemainUuidFirstWithLegacyFallback()
            throws Exception {
        assertFallbackUnitJoin(source("stock/StockQueryService.java"),
                "u", "g.unit_id", "g.unit_legacy_id", 1);
        assertFallbackUnitJoin(source("finance/cost/FinanceCostService.java"),
                "u", "g.unit_id", "g.unit_legacy_id", 1);

        String purchase = source("purchase/report/PurchaseReportService.java");
        String supplierJoin = canonical("""
                LEFT JOIN suppliers gsup
                  ON (gsup.id = g.default_supplier_id
                      OR (g.default_supplier_id IS NULL
                          AND gsup.legacy_id = NULLIF(g.vend_legacy_id, 0)))
                """);
        assertThat(occurrences(purchase, supplierJoin))
                .as("UUID-first default-supplier join")
                .isEqualTo(1);
        assertThat(purchase).doesNotContain(canonical(
                "LEFT JOIN suppliers gsup ON gsup.legacy_id = g.vend_legacy_id"));
    }

    private static void assertStrictColorJoin(String source, int expectedCount) {
        String clause = canonical("""
                LEFT JOIN colors resolved_color
                  ON resolved_color.id = COALESCE(b.color_id, component.color_id)
                """);
        assertThat(occurrences(source, clause))
                .as("UUID-only BOM/component color join")
                .isEqualTo(expectedCount);
        assertThat(source).doesNotContain("resolved_color.legacy_id");
    }

    private static void assertStrictUnitJoin(
            String source, String alias, String currentId, int expectedCount) {
        String clause = canonical("LEFT JOIN units " + alias
                + " ON " + alias + ".id = " + currentId);
        assertThat(occurrences(source, clause))
                .as("UUID-only unit join: %s", clause)
                .isEqualTo(expectedCount);
        assertThat(source).doesNotContain(alias + ".legacy_id");
    }

    private static void assertFallbackUnitJoin(
            String source,
            String alias,
            String currentId,
            String legacyId,
            int expectedCount) {
        String clause = canonical("LEFT JOIN units " + alias
                + " ON (" + alias + ".id = " + currentId
                + " OR (" + currentId + " IS NULL AND "
                + alias + ".legacy_id = NULLIF(" + legacyId + ", 0)))");
        assertThat(occurrences(source, clause))
                .as("UUID-first unit join: %s", clause)
                .isEqualTo(expectedCount);
        assertThat(source).doesNotContain(canonical(
                "LEFT JOIN units " + alias + " ON "
                        + alias + ".legacy_id = " + legacyId));
    }

    private static String source(String relativePath) throws IOException {
        return canonical(Files.readString(
                FEATURE_ROOT.resolve(relativePath), StandardCharsets.UTF_8));
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
                .replaceAll("\\(\\s+", "(")
                .replaceAll("\\s+\\)", ")")
                .trim();
    }
}
