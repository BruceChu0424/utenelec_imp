package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class CrossAnalysisReallocationMigrationContractTest {

    private static final Path SCHEMA = Path.of(
            "src/main/resources/db/migration/"
                    + "V309__preplan_cross_analysis_stock_reallocation.sql");
    private static final Path AUDIT = Path.of(
            "src/main/resources/db/migration/"
                    + "V310__refresh_audit_trigger_coverage.sql");

    @Test
    void reallocationHeaderKeepsBothAnalysisEndpointsAndPriorityProgress() throws Exception {
        String sql = compact(SCHEMA);

        assertThat(sql).contains("create table preplan_material_reallocations");
        assertThat(sql).contains("from_analysis_id uuid not null");
        assertThat(sql).contains("from_analysis_material_id uuid not null");
        assertThat(sql).contains("to_analysis_id uuid not null");
        assertThat(sql).contains("to_analysis_material_id uuid not null");
        assertThat(sql).contains("priority_fulfilled_qty numeric(18,4) not null default 0");
        assertThat(sql).contains(
                "status in ('open', 'partial', 'fulfilled', 'reversed', 'cancelled')");
        assertThat(sql).contains("source_version bigint not null");
        assertThat(sql).contains("target_version bigint not null");
        assertThat(sql).contains("source_fingerprint text not null");
        assertThat(sql).contains("target_fingerprint text not null");
        assertThat(sql).contains("unique (created_by, idempotency_key)");
    }

    @Test
    void appendOnlyEventShapeSupportsPartialLotsAndFormalDemandBridge() throws Exception {
        String sql = compact(SCHEMA);

        assertThat(sql).contains("create table preplan_stock_entitlement_events");
        assertThat(sql).contains("source_entitlement_event_id uuid");
        assertThat(sql).contains("reallocation_id uuid");
        assertThat(sql).contains("source_exact_peg_id uuid");
        assertThat(sql).contains("target_package_id uuid");
        assertThat(sql).contains("target_demand_id uuid");
        assertThat(sql).contains("target_stock_reservation_id uuid");
        assertThat(sql).contains("counter_event_id uuid");
        assertThat(sql).contains("'origin_iqc', 'origin_make'");
        assertThat(sql).contains("'reallocate_in', 'reallocate_out'");
        assertThat(sql).contains("'priority_in', 'priority_out'");
        assertThat(sql).contains("'priority_satisfied_in_place'");
        assertThat(sql).contains("'formalize', 'restore', 'release'");
        assertThat(sql).contains("unique (idempotency_key)");
    }

    @Test
    void lotAndBeneficiaryViewsPreserveOnePhysicalReservationTruth() throws Exception {
        String sql = compact(SCHEMA);

        assertThat(sql).contains("create view v_preplan_stock_entitlement_lot_balance as");
        assertThat(sql).contains("positive.qty - coalesce(consumed.consumed_qty, 0)");
        assertThat(sql).contains("as remaining_qty");
        assertThat(sql).contains(
                "negative.source_entitlement_event_id = positive.id");
        assertThat(sql).contains(
                "create view v_preplan_stock_entitlement_beneficiary_balance as");
        assertThat(sql).contains("sum(lot.remaining_qty)::numeric as effective_qty");
        assertThat(sql).contains("having sum(lot.remaining_qty) > 0");
    }

    @Test
    void makeExactSourceIsMutuallyExclusiveWithIqcDisposition() throws Exception {
        String sql = compact(SCHEMA);

        assertThat(sql).contains("alter column source_disposition_event_id drop not null");
        assertThat(sql).contains("source_stock_document_id uuid");
        assertThat(sql).contains("source_stock_document_item_id uuid");
        assertThat(sql).contains(
                "source_receipt_type in ('purchase', 'subcontract', 'make')");
        assertThat(sql).contains(
                "source_receipt_type = 'make' and source_disposition_event_id is null");
        assertThat(sql).contains("source_receipt_id = source_stock_document_id");
    }

    @Test
    void onlyTheTwoNewBusinessTablesReceiveExplicitAuditTriggers() throws Exception {
        String sql = compact(AUDIT);

        assertThat(sql).contains("trg_audit_preplan_material_reallocations");
        assertThat(sql).contains("on preplan_material_reallocations");
        assertThat(sql).contains("trg_audit_preplan_stock_entitlement_events");
        assertThat(sql).contains("on preplan_stock_entitlement_events");
        assertThat(sql).contains("for each row execute function fn_audit()");
        assertThat(sql).doesNotContain("from pg_class");
        assertThat(sql).doesNotContain("create trigger trg_audit_%");
    }

    @Test
    void migrationDoesNotGuessLegacyV298Ownership() throws Exception {
        String sql = compact(SCHEMA);

        assertThat(sql).doesNotContain("insert into preplan_stock_entitlement_events");
    }

    private static String compact(Path path) throws Exception {
        return Files.readString(path, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
