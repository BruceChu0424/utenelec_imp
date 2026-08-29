package com.uten.imp.features.production.dailyreport;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionReportGeneratedDocumentUuidContractTest {

    @Test
    void v268AddsRestrictiveUuidSourcesWithoutGuessingHistoricalFreeText() throws IOException {
        String sql = canonical(source("src/main/resources/db/migration/"
                + "V268__production_report_generated_document_uuid.sql"));

        assertThat(sql).contains("ALTER TABLE stock_documents ADD COLUMN source_daily_report_id UUID");
        assertThat(sql).contains("ALTER TABLE production_plans ADD COLUMN source_daily_report_id UUID");
        assertThat(sql).contains("FOREIGN KEY (source_daily_report_id) REFERENCES production_daily_reports(id) ON DELETE RESTRICT NOT VALID");
        assertThat(sql).contains("VALIDATE CONSTRAINT fk_stock_documents_source_daily_report");
        assertThat(sql).contains("VALIDATE CONSTRAINT fk_production_plans_source_daily_report");
        assertThat(sql).contains("CREATE INDEX idx_stock_documents_source_daily_report");
        assertThat(sql).contains("CREATE INDEX idx_production_plans_source_daily_report");
        assertThat(sql).doesNotContain("UPDATE stock_documents");
        assertThat(sql).doesNotContain("UPDATE production_plans");
        assertThat(sql).doesNotContain("source_doc_no =");
    }

    @Test
    void generatedWritesReverseAndNoticeUseReportUuidWhileNumberRemainsSnapshot() throws IOException {
        String dailyReport = source("src/main/java/com/uten/imp/features/production/"
                + "dailyreport/ProductionDailyReportService.java");
        String finishedInbound = source(
                "src/main/java/com/uten/imp/features/production/dailyreport/"
                        + "ProductionFqcFinishedInboundService.java");
        String fqc = source(
                "src/main/java/com/uten/imp/features/production/quality/"
                        + "ProductionFqcInspectionService.java");
        String notice = source("src/main/java/com/uten/imp/features/notice/ChainNoticeService.java");
        String stockEntity = source("src/main/java/com/uten/imp/features/stock/StockDocument.java");
        String planEntity = source("src/main/java/com/uten/imp/features/production/plan/ProductionPlan.java");

        assertThat(dailyReport)
                .contains("qualityInspection.registerApprovedReport(r.getId())")
                .doesNotContain("createFinishedInDraft(");
        assertThat(finishedInbound)
                .contains("document.setSourceDailyReportId((UUID) row[0])")
                .contains("item.setSourceDailyReportItemId((UUID) row[6])")
                .contains("production_fqc_inspections inspection")
                .contains("production_fqc_decision_events decision");
        assertThat(fqc)
                .contains("finishedInbound.createReleasedDraft(")
                .contains("allocateReleasedQuantity(");
        assertThat(dailyReport).contains("rp.setSourceDailyReportId(r.getId())");
        assertThat(dailyReport).contains("docsBySource(\"FINISHED_IN\", r.getId())");
        assertThat(dailyReport).contains("remakePlansOf(r.getId())");
        assertThat(dailyReport).contains("source_daily_report_id = :reportId");
        assertThat(dailyReport).doesNotContain("docsBySource(\"FINISHED_IN\", r.getBillNo())");
        assertThat(dailyReport).doesNotContain("WHERE source_doc_no = :no");

        assertThat(notice).contains("notifyRemakeCreated(UUID reportId)");
        assertThat(notice).contains("WHERE rp.source_daily_report_id = ?");
        assertThat(notice).doesNotContain("WHERE rp.source_doc_no = ?");
        assertThat(stockEntity).contains("private UUID sourceDailyReportId");
        assertThat(planEntity).contains("private UUID sourceDailyReportId");
    }

    @Test
    void legacyImportLeavesUnprovableUuidSourcesNull() throws IOException {
        String stockLegacy = source("legacy_migration/migrate_stock_docs.sql");
        String productionLegacy = source("legacy_migration/migrate_production.sql");

        assertThat(stockLegacy).contains("source_daily_report_id)");
        assertThat(stockLegacy).contains("NULL::uuid  -- 历史自由文本不能证明来源报工关系");
        assertThat(productionLegacy).contains("source_daily_report_id)");
        assertThat(productionLegacy).contains("NULL::uuid  -- 历史计划没有可证明的报工来源 UUID");
    }

    private static String source(String serverRelativePath) throws IOException {
        Path direct = Path.of(serverRelativePath);
        Path path = Files.exists(direct) ? direct : Path.of("server").resolve(serverRelativePath);
        return Files.readString(path, StandardCharsets.UTF_8);
    }

    private static String canonical(String value) {
        return value.replaceAll("\\s+", " ").trim();
    }
}
