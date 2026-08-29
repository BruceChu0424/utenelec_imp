package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionFqcRecoveryAndLegacyCutoverMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V414__production_fqc_recovery_and_legacy_cutover.sql");

    @Test
    void legacyBypassIsExplicitMigrationOnlyAndAppendOnly() throws Exception {
        String sql = compact();
        assertThat(sql)
                .contains("create table production_fqc_legacy_exemptions")
                .contains("insert into production_fqc_legacy_exemptions")
                .contains("where not exists ( select 1 from production_fqc_inspections")
                .contains("legacy exemptions are migration-only and append-only")
                .contains("enable always trigger trg_guard_production_fqc_legacy_exemption");
    }

    @Test
    void failureAdjustmentAndRecoveryIdentityAreExactAndAppendOnly() throws Exception {
        String sql = compact();
        assertThat(sql)
                .contains("create table production_fqc_recovery_authorizations")
                .contains("foreign key (source_inspection_id, source_decision_event_id)")
                .contains("foreign key (source_inspection_id, source_report_item_id)")
                .contains("create table production_fqc_contribution_adjustments")
                .contains("decision.fail_qty <> new.adjusted_qty")
                .contains("decision.fail_qty <> new.authorized_qty")
                .contains("production_fqc_contribution_adjustment_guard")
                .contains("enable always trigger trg_guard_fqc_contribution_adjustment_append_only");
    }

    @Test
    void recoveryAllocationIsBalancedReversibleAndNullSafe() throws Exception {
        String sql = compact();
        assertThat(sql)
                .contains("create table production_fqc_recovery_allocation_events")
                .contains("event_type in ('allocate', 'release')")
                .contains("is distinct from recovery_auth.id")
                .contains("report_status is distinct from 1")
                .contains("report_status is distinct from -1")
                .contains("current_allocated < 0 or current_allocated > recovery_auth.authorized_qty")
                .contains("zero active replacement allocation")
                .contains("allocated fqc recovery report identity is immutable")
                .contains("old.report_id is distinct from new.report_id")
                .contains("old.is_deleted is distinct from new.is_deleted")
                .contains("replacement_inspection.status = 'cancelled'")
                .contains("production_fqc_recovery_child_guard");
    }

    @Test
    void scrapRejectCreatePlanningTaskButCannotBypassMaterialGate() throws Exception {
        String sql = compact();
        assertThat(sql)
                .contains("create table production_fqc_replenishment_tasks")
                .contains("create table production_fqc_replenishment_analysis_links")
                .contains("recovery_auth.disposition_code not in ('scrap', 'reject')")
                .contains("analysis_item.source_type <> 'rework'")
                .contains("scrap/reject recovery requires a new kitted production segment")
                .contains("production_fqc_recovery_material_gate");
    }

    @Test
    void recoveryReportsDoNotDoubleConsumeFrozenSalesAllocation() throws Exception {
        String sql = compact();
        assertThat(sql)
                .contains("item.fqc_recovery_authorization_id is null")
                .contains("daily report quantity exceeds its segment sales allocation")
                .contains("finished-in quantity exceeds approved report quantity");
    }

    private static String compact() throws Exception {
        return Files.readString(MIGRATION)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
