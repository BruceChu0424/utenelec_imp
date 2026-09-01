package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SubcontractPreparationEntitlementHandoffMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V447__subcontract_preparation_entitlement_handoff.sql");

    @Test
    void v447AddsFiveAppendOnlyAuditedHandoffFacts() throws Exception {
        String sql = compact();
        assertThat(sql)
                .contains("create table preplan_subcontract_requirement_handoffs")
                .contains("create table preplan_subcontract_requirement_handoff_items")
                .contains("create table preplan_subcontract_requirement_supply_claims")
                .contains("create table preplan_subcontract_entitlement_handoff_slices")
                .contains("create table preplan_subcontract_requirement_handoff_events")
                .contains("preplan subcontract handoff facts are append-only")
                .contains("trg_audit_preplan_subcontract_requirement_handoffs")
                .contains("trg_audit_preplan_subcontract_requirement_handoff_items")
                .contains("trg_audit_preplan_subcontract_requirement_supply_claims")
                .contains("trg_audit_preplan_subcontract_entitlement_handoff_slices")
                .contains("trg_audit_preplan_subcontract_requirement_handoff_events");
    }

    @Test
    void v447MapsRelativeBomUuidPathsAndNeverGuessesLegacyPoolStock()
            throws Exception {
        String sql = compact();
        assertThat(sql)
                .contains("relative_bom_path uuid[] not null")
                .contains("relative_bom_path[cardinality(relative_bom_path)] = bom_item_id")
                .contains("source_relative is distinct from new.relative_bom_path")
                .contains("target_relative is distinct from new.relative_bom_path")
                .contains("source_material.bom_item_id is distinct from new.bom_item_id")
                .contains("target_material.goods_id is distinct from new.goods_id")
                .contains("target_material.color_id is distinct from new.color_id")
                .contains("target_material.unit_id is distinct from new.unit_id")
                .contains("historical v298 pool reservations are never guessed");
    }

    @Test
    void v447SeparatesParentRequirementClaimsFutureSupplyAndExactLots()
            throws Exception {
        String sql = compact();
        assertThat(sql)
                .contains("event_type in ('takeover', 'restore')")
                .contains("v_preplan_subcontract_parent_output_claim_balance")
                .contains("active_parent_output_qty")
                .contains("v_preplan_subcontract_target_future_supply")
                .contains("active subcontract preparation claims exceed source allocation capacity")
                .contains("subcontract requirement takeover must equal parent output")
                .contains("state.state = 'active'");
    }

    @Test
    void v447ExtendsEntitlementConservationWithPairedOutInAndControlledRestore()
            throws Exception {
        String sql = compact();
        assertThat(sql)
                .contains("'subcontract_handoff_out'")
                .contains("'subcontract_handoff_in'")
                .contains("uq_preplan_subcontract_handoff_out_group")
                .contains("uq_preplan_subcontract_handoff_in_group")
                .contains("uq_preplan_subcontract_handoff_in_counter")
                .contains("subcontract entitlement out/in totals must equal slice quantity")
                .contains("must release/restore every exact slice in full")
                .contains("'make_delegate_out', 'subcontract_handoff_out'")
                .contains("'make_delegate_in', 'subcontract_handoff_in'")
                .contains("counter_event.event_type not in (")
                .contains("'make_delegate_out', 'subcontract_handoff_out'");
    }

    @Test
    void v447FailsClosedForOldWritersAndUnprovableStartedTasks()
            throws Exception {
        String sql = compact();
        assertThat(sql)
                .contains("v447 cannot prove a pre-existing source-linked subcontract preparation handoff")
                .contains("source-linked subcontract preparation requires an exact v447 handoff")
                .contains("subcontract_preparation_handoff_required_guard")
                .contains("deferrable initially deferred")
                .doesNotContain("update preplan_analysis_stock_exact_pegs")
                .doesNotContain("update stock_reservations set owner_id");
    }

    private static String compact() throws Exception {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .toLowerCase()
                .replaceAll("\\s+", " ");
    }
}
