package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionFqcQualityReleaseMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V410__production_fqc_quality_release.sql");

    @Test
    void inspectionIsExactToOneApprovedReportLineAndHasNoHistoricalBackfill()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("create table production_fqc_inspections")
                .contains("source_report_item_id uuid not null unique")
                .contains("references production_daily_report_items(id) on delete restrict")
                .contains("source_plan_item_id uuid not null")
                .contains("execution_segment_id uuid not null")
                .contains("reported_qty > 0")
                .contains("passed_qty + failed_qty <= reported_qty")
                .contains("status in ('pending', 'partial', 'resolved')")
                .contains("source_row.report_status <> 1")
                .contains("source_row.segment_status <> 'in_progress'")
                .contains("source_row.package_status <> 'confirmed'")
                .contains("production_fqc_source_report_guard")
                .contains("no historical backfill")
                .doesNotContain("insert into production_fqc_inspections select");
    }

    @Test
    void decisionsAreIdempotentAppendOnlyAndConserveReportedQuantity()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("create table production_fqc_decision_events")
                .contains("decision in ('pass', 'partial', 'fail')")
                .contains("decision = 'partial' and pass_qty > 0 and fail_qty > 0")
                .contains("disposition_code in ('rework', 'scrap', 'reject')")
                .contains("unique (inspection_id, idempotency_key)")
                .contains("request_hash ~ '^[0-9a-f]{64}$'")
                .contains("production fqc decisions exceed reported quantity")
                .contains("production fqc decision and release ledgers are append-only")
                .contains("enable always trigger trg_guard_production_fqc_decision_append_only")
                .contains("trg_apply_production_fqc_decision");
    }

    @Test
    void onlyPassLotsCanAuthorizeAnExactFinishedInboundLine()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("create table production_fqc_release_commands")
                .contains("stock_document_item_id uuid not null unique")
                .contains("create table production_fqc_release_allocations")
                .contains("references production_fqc_decision_events(inspection_id, id)")
                .contains("stock_row.bill_type <> 'finished_in'")
                .contains("stock_row.document_status <> 0")
                .contains("stock_row.source_daily_report_item_id <> inspection.source_report_item_id")
                .contains("fqc release allocations must equal requested quantity")
                .contains("allocated_pass_qty > pass_qty")
                .contains("fqc finished_in allocation exceeds pass quantity")
                .contains("deferrable initially deferred")
                .contains("trg_validate_production_fqc_release_command")
                .contains("trg_validate_production_fqc_release_allocation");
    }

    @Test
    void permissionsSplitViewFromQualityDecisionAndKeepQaPoolExplicit()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("'production_quality_inspection:view'")
                .contains("'production_quality_inspection:approve'")
                .contains("'view', '查看与本人生产单据或品质任务池相关")
                .contains("'approve', '按报工明细 uuid")
                .contains("surface.surface_key = 'quality.inspection'")
                .contains("department.code in ('dept_prod', 'dept_qa')")
                .contains("department.code = 'dept_qa'");
    }

    private static String compact() throws Exception {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
