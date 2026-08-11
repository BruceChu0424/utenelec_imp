package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class BomControlStageMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V247__bom_control_stage_and_packaging_measurement.sql");

    @Test
    void existingBomRowsKeepHistoricalHardStartPerUnitBehavior() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("control_stage text not null default 'start'")
                .contains("consumption_basis text not null default 'per_unit'")
                .contains("basis_output_qty numeric(18,6) not null default 1")
                .contains("allow_partial_package boolean not null default true")
                .contains("hard_gate boolean not null default true")
                .contains("control_stage in ('start', 'assembly', 'finish', 'ship', 'reference')")
                .contains("goods_bom_item_hard_gate_stage_chk check ( not hard_gate or control_stage in ('start', 'assembly', 'finish') )")
                .contains("consumption_basis in ('per_unit', 'per_package', 'fixed_batch')")
                .contains("goods_bom_item_basis_output_qty_chk check ( basis_output_qty > 0 )");
    }

    @Test
    void stageReadinessIsBoundedMonotonicAndKeepsReadyNowEqualToFinish()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("ready_start_qty numeric(18,4) not null default 0")
                .contains("ready_finish_qty numeric(18,4) not null default 0")
                .contains("ready_ship_qty numeric(18,4) not null default 0")
                .contains("ready_start_qty <= requested_qty - submitted_qty - approved_qty")
                .contains("ready_finish_qty <= requested_qty - submitted_qty - approved_qty")
                .contains("ready_ship_qty <= requested_qty - submitted_qty - approved_qty")
                .contains("ready_ship_qty <= ready_finish_qty")
                .contains("ready_finish_qty <= ready_start_qty")
                .contains(
                        "reference shipment forecast bounded by ready_finish_qty; "
                                + "not a stock reservation or formal shipment gate.")
                .contains("set ready_start_qty = ready_now_qty, ready_finish_qty = ready_now_qty, ready_ship_qty = ready_now_qty")
                .contains("pma_item_ready_now_is_finish_chk check ( ready_now_qty = ready_finish_qty )")
                .doesNotContain("ready_start_qty <= ready_finish_qty")
                .doesNotContain("ready_finish_qty <= ready_ship_qty");
    }

    @Test
    void planLinkTriggerTransfersLinearReadinessAndClearsNonlinearOrReleasedClaims()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("create or replace function fn_sync_material_analysis_plan_link_qty()")
                .contains("v_next_submitted := v_item.submitted_qty - v_old_submitted + v_new_submitted")
                .contains("v_next_approved := v_item.approved_qty - v_old_approved + v_new_approved")
                .contains("v_item_remaining := v_item.requested_qty - v_next_submitted - v_next_approved")
                .contains("set submitted_qty = v_next_submitted, approved_qty = v_next_approved")
                .contains("when v_old_claim > v_new_claim or v_has_nonlinear_claim then 0")
                .contains("greatest(ready_now_qty - (v_new_claim - v_old_claim), 0)")
                .contains("greatest(ready_by_date_qty - (v_new_claim - v_old_claim), 0)")
                .contains("greatest(ready_start_qty - (v_new_claim - v_old_claim), 0)")
                .contains("greatest(ready_finish_qty - (v_new_claim - v_old_claim), 0)")
                .contains("greatest(ready_ship_qty - (v_new_claim - v_old_claim), 0)")
                .contains("else least(ready_now_qty, v_item_remaining)")
                .contains("else least(ready_by_date_qty, v_item_remaining)")
                .contains("else least(ready_start_qty, v_item_remaining)")
                .contains("else least(ready_finish_qty, v_item_remaining)")
                .contains("else least(ready_ship_qty, v_item_remaining)")
                .doesNotContain("requested_qty - (submitted_qty - v_old_submitted");
    }

    @Test
    void planLinkExchangeUsesExactRemainingAndPropagatesParentShortage()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("create or replace function fn_material_analysis_edge_required(")
                .contains("when p_consumption_basis = 'per_unit' then p_parent_output_qty * p_bom_qty")
                .contains("when p_consumption_basis = 'per_package' and p_allow_partial_package then p_parent_output_qty * p_bom_qty / p_basis_output_qty")
                .contains("when p_consumption_basis in ('per_package', 'fixed_batch') then ceil(p_parent_output_qty / p_basis_output_qty) * p_bom_qty")
                .contains("with recursive exact_requirements as")
                .contains("v_old_remaining * material.parent_per_product_qty")
                .contains("v_item_remaining * material.parent_per_product_qty")
                .contains("fn_material_analysis_edge_required( parent.old_required")
                .contains("fn_material_analysis_edge_required( parent.new_shortage")
                .contains("fn_material_analysis_edge_required( parent.claim_required")
                .contains("coalesce(material.confirmed_route, material.source_suggestion) as effective_route")
                .contains("parent.effective_route = 'make' and parent.control_stage <> 'reference'")
                .contains("requirement.new_required - allocation.new_physical_allocated, 0) as new_shortage")
                .contains("set required_qty = adjusted.new_required")
                .contains("when v_new_claim < v_old_claim then 0::numeric")
                .contains("material.allocated_available_qty - requirement.claim_required")
                .contains("v_has_nonlinear_claim")
                .contains("material analysis snapshot tree is incomplete")
                .doesNotContain("required_qty - per_product_qty * v_claim_delta");
    }

    @Test
    void analysisNodesSnapshotControlAndRawEdgeQuantities() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("alter table production_material_analysis_materials")
                .contains("add column control_stage text not null default 'start'")
                .contains("add column consumption_basis text not null default 'per_unit'")
                .contains("add column calculation_mode text not null default 'legacy_cumulative_per_unit'")
                .contains("add column bom_qty numeric(18,6)")
                .contains("add column parent_per_product_qty numeric(18,6) not null default 1")
                .contains("add column allocated_start_qty numeric(18,4) not null default 0")
                .contains("add column allocated_finish_qty numeric(18,4) not null default 0")
                .contains("add column allocated_ship_qty numeric(18,4) not null default 0")
                .contains("pma_material_hard_gate_stage_chk check ( not hard_gate or control_stage in ('start', 'assembly', 'finish') )")
                .contains("set bom_qty = per_product_qty, parent_per_product_qty = 1, allocated_start_qty = allocated_available_qty")
                .doesNotContain("set bom_qty = bom.qty")
                .contains("alter column bom_qty set not null")
                .contains("calculation_mode in ('legacy_cumulative_per_unit', 'edge_rule')")
                .contains("alter column calculation_mode set default 'edge_rule'")
                .contains("production_material_analysis_material_bom_qty_chk check ( bom_qty > 0 )")
                .contains("pma_material_parent_per_product_qty_chk check ( parent_per_product_qty > 0 )")
                .contains("pma_material_tree_shape_chk check ( (depth = 1 and parent_node_key is null) or (depth > 1 and parent_node_key is not null) )");
        assertThat(sql).contains(
                "create index idx_pma_material_active_tree on production_material_analysis_materials( analysis_item_id, parent_node_key, depth ) where active = true");
    }

    @Test
    void legacySnapshotsRebaseFromFrozenCumulativeUsageAndInvalidatePreviews()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("material.calculation_mode = 'legacy_cumulative_per_unit'")
                .contains("source.requested_qty - source.submitted_qty - source.approved_qty")
                .contains("material.per_product_qty, 'per_unit', 1, true")
                .contains("set required_qty = legacy.required_qty")
                .contains("fingerprint || '|v247-legacy-rebase|' || version::text")
                .contains("preview_fingerprint = null");
    }

    @Test
    void appendOnlyDeleteIsRejectedBeforeNewRowFieldsAreRead() throws Exception {
        String sql = compact();
        int deleteGuard = sql.indexOf("if tg_op = 'delete' then");
        int newAnalysisRead = sql.indexOf("where id = new.analysis_id");

        assertThat(deleteGuard).isGreaterThanOrEqualTo(0);
        assertThat(newAnalysisRead).isGreaterThan(deleteGuard);
    }

    private static String compact() throws Exception {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
