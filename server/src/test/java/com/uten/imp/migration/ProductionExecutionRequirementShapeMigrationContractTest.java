package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionExecutionRequirementShapeMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V249__execution_segment_material_requirement_shape.sql");

    @Test
    void freezesDemandedOrEvidenceBackedZeroMaterialShape() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("material_requirement_mode text not null default 'demanded'")
                .contains("material_requirement_mode = 'demanded' and zero_material_reason is null")
                .contains("material_requirement_mode = 'zero_material'")
                .contains("zero_material_reason = 'direct_make' and zero_material_analysis_id is not null")
                .contains("zero_material_reason = 'plan_bom_override' and zero_material_analysis_id is not null")
                .contains("length(btrim(zero_material_exception_reason)) between 2 and 1000")
                .contains("zero_material_authorized_by is not null")
                .contains("zero_material_reason = 'no_production_hard_gate' and zero_material_analysis_id is null")
                .contains("old.material_requirement_mode is distinct from new.material_requirement_mode")
                .contains("old.zero_material_reason is distinct from new.zero_material_reason")
                .contains("old.zero_material_exception_reason is distinct from new.zero_material_exception_reason")
                .contains("old.zero_material_authorized_by is distinct from new.zero_material_authorized_by")
                .contains("product.production_bom_policy = 'direct_make'")
                .contains("product.production_bom_policy = 'bom_required'")
                .contains("btrim(plan.bom_override_reason) = new.zero_material_exception_reason")
                .contains("bom.control_stage in ( 'start', 'assembly', 'finish')")
                .contains("production_execution_segment_zero_evidence_guard")
                .contains("production_execution_segment_requirement_immutable_guard");
    }

    @Test
    void deferredIntegrityRequiresExactDemandCardinalityAndNoZeroDraw()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("v_segment.material_requirement_mode = 'demanded' and v_demand_count = 0")
                .contains("v_segment.material_requirement_mode = 'zero_material' and v_demand_count <> 0")
                .contains("v_segment.material_requirement_mode = 'zero_material' then")
                .contains("v_segment.status = 'waiting'")
                .contains("document.execution_segment_id = v_segment.id")
                .contains("document.document_type = 'draw'")
                .contains("production_execution_segment_zero_draw_guard");
    }

    @Test
    void historicalZeroDemandRowsFailClosedInsteadOfUsingMutableBomState()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("existing confirmed zero-demand segment needs evidence-backed classification before v249")
                .contains("production_execution_segment_zero_migration_guard")
                .doesNotContain("update production_execution_segments set material_requirement_mode = 'zero_material'");
    }

    @Test
    void zeroMaterialSegmentsAreDispatchReadyInSharedExecutionView()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("drop view v_production_execution_segments")
                .contains("create view v_production_execution_segments")
                .contains("when segment.material_requirement_mode = 'zero_material' then true")
                .contains("else coalesce(bool_and(material.ready), false)");
    }

    @Test
    void zeroMaterialOnlyPlansDoNotNeedFakeClearanceRowsToClose()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("create or replace function fn_guard_production_plan_material_close()")
                .contains("not exists ( select 1 from v_production_material_clearance clearance where clearance.plan_id = new.id )")
                .contains("segment.material_requirement_mode = 'demanded'")
                .contains("segment.status <> 'completed'");
    }

    private static String compact() throws Exception {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
