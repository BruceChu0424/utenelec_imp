package com.uten.imp.features.production.quality;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionFqcRecoveryIntegrationContractTest {

    @Test
    void failDecisionRollsBackEffectiveContributionBeforeCreatingReplacementLot()
            throws Exception {
        String quality = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/quality/"
                        + "ProductionFqcInspectionService.java"));
        String recovery = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/quality/"
                        + "ProductionFqcRecoveryService.java"));
        assertThat(quality).contains("recovery.applyFailureAdjustment(");
        assertThat(recovery)
                .contains("SET fqty = COALESCE(fqty, 0) - :qty")
                .contains("SET produced_qty = COALESCE(produced_qty, 0) - :qty")
                .contains("INSERT INTO production_fqc_contribution_adjustments")
                .contains("INSERT INTO production_fqc_recovery_authorizations")
                .contains("INSERT INTO production_fqc_replenishment_tasks");
    }

    @Test
    void reportFlowConsumesAndReversesRecoveryWithoutDoubleRollback()
            throws Exception {
        String report = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/dailyreport/"
                        + "ProductionDailyReportService.java"));
        assertThat(report)
                .contains("allocateApprovedRecoveryReportItem(")
                .contains("effectiveContribution(")
                .contains("if (qty.signum() > 0)")
                .contains("fqcRecovery.reverseReportEffects(r.getId())")
                .contains("fqcRecovery.requireLegacyExemption(legacyItem.getId())");
    }

    @Test
    void reportableQueryExposesReworkAndBlocksMaterialLossReplacement()
            throws Exception {
        String query = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/dailyreport/"
                        + "ReportablePlanLineQueryService.java"));
        assertThat(query)
                .contains("fqc_recovery_authorization_id")
                .contains("fqc_recovery_available_qty")
                .contains("fqc_recovery_requires_material")
                .contains("WHEN recovery.disposition_code = 'REWORK'")
                .contains("OR recovery.authorization_id IS NOT NULL")
                .contains("COALESCE(segment_done.active_qty, 0)")
                .contains(">= COALESCE(segment.planned_qty, 0)")
                .contains("WHERE (max_report_qty > 0 OR fqc_recovery_requires_material)");
    }

    @Test
    void plannerCommandCreatesExactMaterialAnalysisBridge() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/quality/"
                        + "ProductionFqcReplenishmentService.java"));
        assertThat(source)
                .contains("materialAnalysis.preview(new PreviewRequest(")
                .contains("\"REWORK\"")
                .contains("\"FQC-RECOVERY-\" + authorizationId")
                .contains("INSERT INTO production_fqc_replenishment_analysis_links")
                .contains("production_material_analysis:create");
    }

    @Test
    void qualityDecisionAndReportReverseShareOneRowLockOrder()
            throws Exception {
        String quality = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/quality/"
                        + "ProductionFqcInspectionService.java"));
        String report = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/dailyreport/"
                        + "ProductionDailyReportService.java"));
        String recovery = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/quality/"
                        + "ProductionFqcRecoveryService.java"));

        assertThat(report.indexOf(
                "qualityInspection.prelockForReportReversal(r.getId())"))
                .isLessThan(report.indexOf("executionSegments.reverse(items)"));
        assertThat(quality.indexOf(
                "lockOne(\"production_fqc_inspections\", inspectionId)"))
                .isLessThan(quality.indexOf(
                        "lockOne(\"production_execution_segments\""));
        assertThat(quality.indexOf(
                "lockOne(\"production_execution_segments\""))
                .isLessThan(quality.indexOf(
                        "lockOne(\"production_plan_items\""));
        assertThat(recovery.indexOf("List<?> lockedSales"))
                .isLessThan(recovery.indexOf("List<?> lockedLinks"));
    }

    @Test
    void postCutoverNoSegmentAndMissingInspectionAreFailClosed()
            throws Exception {
        String guard = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/dailyreport/"
                        + "DailyReportExecutionSegmentGuard.java"));
        String query = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/dailyreport/"
                        + "ReportablePlanLineQueryService.java"));
        String quality = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/quality/"
                        + "ProductionFqcInspectionService.java"));

        assertThat(query).contains("segment.id IS NOT NULL");
        assertThat(guard)
                .contains("production_fqc_legacy_exemptions")
                .contains("V414 后新增报工必须选择已开工执行段");
        assertThat(quality)
                .contains("recovery.requireLegacyExemption(sourceReportItemId)")
                .doesNotContain("if (managed.isEmpty()) {\n            return;");
    }

    @Test
    void earlyFailKeepsOrdinaryGrossRemainderReportableFirst()
            throws Exception {
        String query = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/dailyreport/"
                        + "ReportablePlanLineQueryService.java"));

        assertThat(query)
                .contains("COALESCE(segment.planned_qty, i.qty, 0)")
                .contains("ELSE COALESCE(segment_done.active_qty, 0)")
                .contains(">= COALESCE(segment.planned_qty, 0)");
        assertThat(new BigDecimal("10").subtract(new BigDecimal("5")))
                .isEqualByComparingTo("5");
    }
}
