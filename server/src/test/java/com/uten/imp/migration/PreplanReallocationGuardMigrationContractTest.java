package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class PreplanReallocationGuardMigrationContractTest {

    private static final Path SCHEMA = migration(
            "V309__preplan_cross_analysis_stock_reallocation.sql");
    private static final Path AUTHORITY = migration(
            "V311__preplan_reallocation_authority_and_lifecycle.sql");
    private static final Path MAKE = migration(
            "V312__preplan_make_exact_provenance_guard.sql");
    private static final Path CONSERVATION = migration(
            "V313__preplan_entitlement_conservation_and_backfill.sql");

    @Test
    void lifecycleHasDualCasPermissionCloseReplayAndNoScalarDemandBinding()
            throws Exception {
        String schema = compact(SCHEMA);
        String sql = compact(AUTHORITY);

        assertThat(schema).doesNotContain("priority_target_demand_id");
        assertThat(sql).contains("close_idempotency_key text");
        assertThat(sql).contains("close_request_hash text");
        assertThat(sql).contains("'borrow', 'borrow_revoke'");
        assertThat(sql).contains("'cross_reallocate', 'cross_reallocate_revoke'");
        assertThat(sql).contains(
                "production_material_analysis:cross_reallocate");
        assertThat(sql).contains("department.code in ('gm', 'sub_plan')");
        assertThat(sql).doesNotContain("department.code in ('gm', 'dept_pmc'");
    }

    @Test
    void makeUsesFinishedInboundProvenanceAndOwnOriginReason() throws Exception {
        String sql = compact(MAKE);

        assertThat(sql).contains("new.source_receipt_type = 'make'");
        assertThat(sql).contains("stock_document.doc_type <> 'finished_in'");
        assertThat(sql).contains("child_item.source_type <> 'make_component'");
        assertThat(sql).contains(
                "child_item.parent_analysis_material_id <> new.origin_analysis_material_id");
        assertThat(sql).contains("new.beneficiary_reason <> 'origin_make'");
    }

    @Test
    void eventLotsAreAppendOnlyConservedAndBackfillOnlyProvableExactRows()
            throws Exception {
        String sql = compact(CONSERVATION);

        assertThat(sql).contains("entitlement events are append-only");
        assertThat(sql).contains("event exceeds source entitlement lot");
        assertThat(sql).contains("target_linked + new.qty > target_reservation.qty");
        assertThat(sql).contains("preplan_entitlement_physical_conservation_guard");
        assertThat(sql).contains("reallocation out/in totals must equal header quantity");
        assertThat(sql).contains(
                "from preplan_analysis_stock_exact_pegs exact join stock_reservations reservation");
        assertThat(sql).contains("exact.source_receipt_type in ('purchase', 'subcontract')");
        assertThat(sql).doesNotContain("from stock_reservations reservation where reservation.owner_type = 'preplan_analysis'");
    }

    private static Path migration(String name) {
        return Path.of("src/main/resources/db/migration", name);
    }

    private static String compact(Path path) throws Exception {
        return Files.readString(path, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
