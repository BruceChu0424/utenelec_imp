-- V426: strengthen the immutable evidence for new zero-material DIRECT_MAKE
-- execution segments without changing historical V249/V423 migration bytes.
--
-- A plan-level material_analysis_id is not enough: the execution segment must
-- point to the exact plan item, and that plan item must match the exact active
-- analysis item by goods/color/unit. DIRECT_MAKE also remains the no-child
-- shape: neither the current goods structure nor the frozen active analysis
-- snapshot may contain production material rows.

ALTER TABLE production_execution_segments
    ADD CONSTRAINT production_execution_segment_zero_reason_required_chk
        CHECK (
            material_requirement_mode <> 'ZERO_MATERIAL'
            OR zero_material_reason IS NOT NULL
        );

CREATE OR REPLACE FUNCTION fn_guard_execution_segment_requirement_shape()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.material_requirement_mode = 'ZERO_MATERIAL'
       AND NEW.status = 'WAITING' THEN
        RAISE EXCEPTION 'zero-material execution segment must start READY'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_execution_segment_zero_ready_guard';
    END IF;
    IF TG_OP = 'INSERT'
       AND NEW.material_requirement_mode = 'ZERO_MATERIAL'
       AND (
           NEW.zero_material_reason IS NULL
           OR NOT (
           (
               NEW.zero_material_reason = 'DIRECT_MAKE'
               AND EXISTS (
                   SELECT 1
                   FROM production_plans plan
                   JOIN production_plan_items plan_item
                     ON plan_item.plan_id = plan.id
                    AND plan_item.id = NEW.source_plan_item_id
                    AND plan_item.is_deleted = FALSE
                   JOIN production_material_analysis_items analysis_item
                     ON analysis_item.analysis_id = plan.material_analysis_id
                    AND analysis_item.id = plan.material_analysis_item_id
                    AND analysis_item.is_deleted = FALSE
                   WHERE plan.id = NEW.plan_id
                     AND plan.is_deleted = FALSE
                     AND plan.material_analysis_id =
                         NEW.zero_material_analysis_id
                     AND plan_item.goods_id = NEW.product_goods_id
                     AND plan_item.color_id IS NOT DISTINCT FROM
                         NEW.product_color_id
                     AND plan_item.unit_id = NEW.product_unit_id
                     AND analysis_item.goods_id = NEW.product_goods_id
                     AND analysis_item.color_id IS NOT DISTINCT FROM
                         NEW.product_color_id
                     AND analysis_item.unit_id = NEW.product_unit_id
                     AND NOT EXISTS (
                         SELECT 1
                         FROM goods_bom_items bom
                         WHERE bom.goods_id = NEW.product_goods_id
                           AND bom.is_deleted = FALSE
                     )
                     AND NOT EXISTS (
                         SELECT 1
                         FROM production_material_analysis_materials material
                         WHERE material.analysis_id = plan.material_analysis_id
                           AND material.analysis_item_id =
                               plan.material_analysis_item_id
                           AND material.active = TRUE
                     )
               )
           )
           OR
           (
               NEW.zero_material_reason = 'NO_PRODUCTION_HARD_GATE'
               AND EXISTS (
                   SELECT 1
                   FROM goods_bom_items bom
                   WHERE bom.goods_id = NEW.product_goods_id
                     AND bom.is_deleted = FALSE
               )
               AND NOT EXISTS (
                   SELECT 1
                   FROM goods_bom_items bom
                   WHERE bom.goods_id = NEW.product_goods_id
                     AND bom.is_deleted = FALSE
                     AND bom.hard_gate = TRUE
                     AND bom.control_stage IN (
                         'START', 'ASSEMBLY', 'FINISH')
               )
           )
           )
       ) THEN
        RAISE EXCEPTION 'zero-material evidence does not match the plan/BOM facts'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_execution_segment_zero_evidence_guard';
    END IF;
    IF TG_OP = 'UPDATE'
       AND (
           OLD.material_requirement_mode
               IS DISTINCT FROM NEW.material_requirement_mode
           OR OLD.zero_material_reason
               IS DISTINCT FROM NEW.zero_material_reason
           OR OLD.zero_material_analysis_id
               IS DISTINCT FROM NEW.zero_material_analysis_id
           OR OLD.zero_material_exception_reason
               IS DISTINCT FROM NEW.zero_material_exception_reason
           OR OLD.zero_material_authorized_by
               IS DISTINCT FROM NEW.zero_material_authorized_by
       ) THEN
        RAISE EXCEPTION 'execution segment material requirement shape is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_execution_segment_requirement_immutable_guard';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fn_guard_execution_segment_requirement_shape() IS
    'V426: validates exact analysis/plan-item lineage for new DIRECT_MAKE zero-material segments.';
