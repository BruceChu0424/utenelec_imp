package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionMaterialAnalysisMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/V234__production_material_analysis.sql");

    @Test
    void manualSourcesAndReasonsFailClosedOnNull() throws Exception {
        String sql = compact();

        assertThat(sql).contains("source_reason is not null");
        assertThat(sql).contains("route_reason is not null");
        assertThat(sql).contains("cancellation_reason is not null");
        assertThat(sql).contains("bom_override_reason is not null");
        assertThat(sql).contains("initial_idempotency_key text not null");
    }

    @Test
    void aggregateOwnershipAndQuantityConservationAreDatabaseEnforced() throws Exception {
        String sql = compact();

        assertThat(sql).contains("foreign key (analysis_id, analysis_item_id)");
        assertThat(sql).contains("references production_material_analysis_items(analysis_id, id)");
        assertThat(sql).contains("foreign key (analysis_id, action_id)");
        assertThat(sql).contains("foreign key (analysis_id, analysis_material_id)");
        assertThat(sql).contains("trg_check_preplan_supply_action_allocation");
        assertThat(sql).contains("submitted_qty + approved_qty <= requested_qty");
        assertThat(sql).contains("linked production plan is not the same active analysis draft");
        assertThat(sql).contains("when v_remaining = 0 then 'completed'");
        assertThat(sql).contains("when v_used > 0 then 'partially_planned'");
    }

    @Test
    void downstreamActionsHaveStableGroupGenerationAndExactExternalAnchors() throws Exception {
        String sql = compact();

        assertThat(sql).contains("action_group_key text not null");
        assertThat(sql).contains("request_business_key text not null");
        assertThat(sql).contains("predecessor_action_id uuid");
        assertThat(sql).contains("uq_preplan_supply_action_group_generation");
        assertThat(sql).contains("external_item_id uuid");
        assertThat(sql).contains("'purchase_request', 'subcontract_application', 'preplan_make_task'");
        assertThat(sql).contains("'preview', 'route', 'reallocate', 'notify', 'generate_plan'");
    }

    @Test
    void bomOverrideIsNotGrantedByDepartmentAndApprovalIsIndependent() throws Exception {
        String sql = compact();

        assertThat(sql).contains("'production_material_analysis:bom_override'");
        assertThat(sql).contains("p.code = 'production_plan:approve'");
        assertThat(sql).doesNotContain("p.code in ('production_material_analysis:bom_override'");
        assertThat(sql).contains("'production_material_analysis:reallocate'");
        assertThat(sql).contains("on production_material_analyses(maker_id, initial_idempotency_key)");
    }

    private static String compact() throws Exception {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
