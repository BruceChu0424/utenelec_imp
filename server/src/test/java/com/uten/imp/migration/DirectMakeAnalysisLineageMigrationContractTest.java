package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/** V426 contract for exact DIRECT_MAKE plan-item and analysis-item lineage. */
class DirectMakeAnalysisLineageMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V426__strengthen_direct_make_analysis_lineage.sql");

    @Test
    void directMakeRequiresExactPlanAndAnalysisItemIdentity() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("create or replace function fn_guard_execution_segment_requirement_shape()")
                .contains("new.zero_material_reason is null or not (")
                .contains("new.zero_material_reason = 'direct_make'")
                .contains("join production_plan_items plan_item")
                .contains("plan_item.id = new.source_plan_item_id")
                .contains("join production_material_analysis_items analysis_item")
                .contains("analysis_item.analysis_id = plan.material_analysis_id")
                .contains("analysis_item.id = plan.material_analysis_item_id")
                .contains("plan.material_analysis_id = new.zero_material_analysis_id")
                .contains("plan_item.goods_id = new.product_goods_id")
                .contains("plan_item.color_id is not distinct from new.product_color_id")
                .contains("plan_item.unit_id = new.product_unit_id")
                .contains("analysis_item.goods_id = new.product_goods_id")
                .contains("analysis_item.color_id is not distinct from new.product_color_id")
                .contains("analysis_item.unit_id = new.product_unit_id");
    }

    @Test
    void directMakeRemainsAProvenNoChildMaterialShape() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("from goods_bom_items bom where bom.goods_id = new.product_goods_id and bom.is_deleted = false")
                .contains("from production_material_analysis_materials material")
                .contains("material.analysis_item_id = plan.material_analysis_item_id")
                .contains("material.active = true")
                .contains("new.zero_material_reason = 'no_production_hard_gate'");
    }

    @Test
    void preservesReadyAndImmutableGuardsWithoutRestoringRetiredPolicy() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("add constraint production_execution_segment_zero_reason_required_chk")
                .contains("material_requirement_mode <> 'zero_material' or zero_material_reason is not null")
                .contains("zero-material execution segment must start ready")
                .contains("execution segment material requirement shape is immutable")
                .doesNotContain("production_bom_policy")
                .doesNotContain("plan_bom_override")
                .doesNotContain("bom_override_reason")
                .doesNotContain("drop column");
    }

    private static String compact() throws Exception {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
