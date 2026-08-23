package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class PreplanStockEntitlementMigrationContractTest {

    private static final Path ROOT = Path.of("src/main/resources/db/migration");

    @Test
    void makeExactUsesApprovedFinishedInboundAndParentAllocationProvenance()
            throws Exception {
        String sql = compact("V312__preplan_make_exact_provenance_guard.sql");

        assertThat(sql).contains("new.source_receipt_type = 'make'");
        assertThat(sql).contains("stock_document.status <> 1");
        assertThat(sql).contains("reservation.supply_type <> 'production_plan_item'");
        assertThat(sql).contains("child_item.source_type <> 'make_component'");
        assertThat(sql).contains("child_item.parent_analysis_material_id <> new.origin_analysis_material_id");
        assertThat(sql).contains("allocation.external_item_id <> child_item.id");
        assertThat(sql).contains("new.beneficiary_reason <> 'origin_make'");
        int capacityStart =
                sql.lastIndexOf("select coalesce(sum(exact.qty), 0)");
        int capacityEnd = sql.indexOf("if allocated_total", capacityStart);
        String capacityGuard = sql.substring(capacityStart, capacityEnd);
        assertThat(capacityGuard)
                .contains("exact_inspection.status <> 'reversed'")
                .contains("exact_stock_document.status = 1")
                .contains("exact_stock_document.is_deleted = false")
                .doesNotContain("released_qty")
                .doesNotContain("release_reason");
    }

    @Test
    void formalizeAndRestoreAreDatabaseConservedAgainstPhysicalReservations()
            throws Exception {
        String sql = compact(
                "V313__preplan_entitlement_conservation_and_backfill.sql");

        assertThat(sql).contains("new.event_type = 'formalize'");
        assertThat(sql).contains("new.target_package_id is null");
        assertThat(sql).contains("target_reservation.owner_type <> 'production_material_demand'");
        assertThat(sql).contains("target_linked + new.qty > target_reservation.qty");
        assertThat(sql).contains("from production_plans where id = demand.plan_id");
        assertThat(sql).contains(
                "production_plan.material_analysis_id is distinct from new.beneficiary_analysis_id");
        assertThat(sql).contains(
                "production_plan.material_analysis_item_id is distinct from material.analysis_item_id");
        assertThat(sql).contains("new.event_type = 'restore'");
        assertThat(sql).contains("uq_preplan_entitlement_restore_counter");
        assertThat(sql).contains("entitlement_qty is distinct from physical_qty");
        assertThat(sql).contains("preplan_entitlement_physical_conservation_guard");
    }

    @Test
    void pairedInboundEventsExplicitlyRejectMissingCounterRows()
            throws Exception {
        String sql = compact(
                "V313__preplan_entitlement_conservation_and_backfill.sql");

        String reallocateIn = sql.substring(
                sql.indexOf("new.event_type = 'reallocate_in'"),
                sql.indexOf("new.event_type = 'priority_out'"));
        String priorityIn = sql.substring(
                sql.indexOf("new.event_type = 'priority_in'"),
                sql.indexOf("new.event_type = 'priority_satisfied_in_place'"));
        assertThat(reallocateIn).contains("counter_event.id is null");
        assertThat(priorityIn).contains("counter_event.id is null");
    }
    @Test
    void originReceiptIdentityComparisonsFailClosedOnNull()
            throws Exception {
        String sql = compact(
                "V313__preplan_entitlement_conservation_and_backfill.sql");

        assertThat(sql).contains(
                "new.source_receipt_type is distinct from exact.source_receipt_type");
        assertThat(sql).contains(
                "new.source_receipt_id is distinct from exact.source_receipt_id");
        assertThat(sql).contains(
                "exact.source_receipt_type is distinct from 'make'");
        assertThat(sql).doesNotContain(
                "new.source_receipt_type <> exact.source_receipt_type");
        assertThat(sql).doesNotContain(
                "new.source_receipt_id <> exact.source_receipt_id");
    }


    @Test
    void migrationBackfillsOnlyProvableV307IqcLotsAndNeverLegacyV298()
            throws Exception {
        String sql = compact(
                "V313__preplan_entitlement_conservation_and_backfill.sql");

        assertThat(sql).contains("from preplan_analysis_stock_exact_pegs exact");
        assertThat(sql).contains("exact.source_receipt_type in ('purchase', 'subcontract')");
        assertThat(sql).contains("event.source_exact_peg_id = exact.id");
        assertThat(sql).doesNotContain(
                "where reservation.owner_type = 'preplan_analysis' and not exists");
    }

    private static String compact(String file) throws Exception {
        return Files.readString(ROOT.resolve(file), StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
