-- V764: 跨基本重量单位换料时, 沿用单重必须换到新料的基本单位。
-- 只修正权威单重求值, 不改 V740 字节, 不回写已结算理论与成本历史。
-- 换算仅使用 V743 的单位量纲登记与千克因子; 缺登记返回 NULL, 交现有缺单重门处理。

CREATE FUNCTION fn_workshop_material_convert_weight(p_qty NUMERIC, p_source_unit UUID, p_target_unit UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN p_qty IS NULL OR p_source_unit IS NULL OR p_target_unit IS NULL THEN NULL
        WHEN p_source_unit = p_target_unit THEN p_qty
        ELSE (
            SELECT p_qty * fn_weight_unit_kg_factor(source.mass_unit_code)
                         / NULLIF(fn_weight_unit_kg_factor(target.mass_unit_code), 0)
            FROM unit_measurement_profiles source
            JOIN unit_measurement_profiles target ON target.unit_id = p_target_unit
            WHERE source.unit_id = p_source_unit
              AND source.measurement_dimension = 'MASS' AND target.measurement_dimension = 'MASS'
              AND source.mass_unit_code IS NOT NULL AND target.mass_unit_code IS NOT NULL)
    END
$$;
COMMENT ON FUNCTION fn_workshop_material_convert_weight(NUMERIC, UUID, UUID) IS
    '车间单重从原料基本单位换到新料基本单位; 同 UUID 保持原值, 跨单位仅认 MASS 登记, 缺配置返回 NULL';

CREATE OR REPLACE FUNCTION fn_workshop_material_unit_weight_step(p_row UUID, p_depth INT,
    OUT unit_weight NUMERIC, OUT weight_source TEXT)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    material_row production_execution_periodic_materials%ROWTYPE;
    material_change production_execution_material_changes%ROWTYPE;
    replaced_row production_execution_periodic_materials%ROWTYPE;
    inherited_unit UUID;
    product UUID;
BEGIN
    IF p_depth > 32 THEN RETURN; END IF;
    SELECT * INTO material_row FROM production_execution_periodic_materials WHERE id = p_row;
    IF NOT FOUND THEN RETURN; END IF;
    SELECT segment.product_goods_id INTO product
    FROM production_execution_segments segment WHERE segment.id = material_row.execution_segment_id;

    IF material_row.origin IN ('BOM', 'CHOICE', 'INHERITED') THEN
        unit_weight := fn_workshop_material_edge_weight(product, material_row.material_goods_id,
            material_row.material_color_id);
        IF unit_weight IS NOT NULL THEN
            weight_source := 'BOM_AT_CLOSE';
            RETURN;
        END IF;
        IF material_row.design_qty_snapshot IS NOT NULL THEN
            unit_weight := material_row.design_qty_snapshot;
            weight_source := 'SEGMENT_SNAPSHOT';
            RETURN;
        END IF;
        IF material_row.origin = 'INHERITED' THEN
            SELECT unit_id INTO inherited_unit FROM production_execution_periodic_materials
            WHERE id = material_row.source_row_id;
            SELECT fn_workshop_material_convert_weight(step.unit_weight, inherited_unit, material_row.unit_id),
                   step.weight_source INTO unit_weight, weight_source
            FROM fn_workshop_material_unit_weight_step(material_row.source_row_id, p_depth + 1) step;
            IF unit_weight IS NULL THEN weight_source := NULL; END IF;
        END IF;
        RETURN;
    END IF;

    SELECT * INTO material_change FROM production_execution_material_changes WHERE id = material_row.change_id;
    IF material_change.weight_basis = 'FROM_REPLACED' AND material_change.from_row_id IS NOT NULL THEN
        SELECT * INTO replaced_row FROM production_execution_periodic_materials WHERE id = material_change.from_row_id;
        IF NOT FOUND THEN RETURN; END IF;
        unit_weight := fn_workshop_material_edge_weight(product, replaced_row.material_goods_id,
            replaced_row.material_color_id);
        IF unit_weight IS NOT NULL THEN
            unit_weight := fn_workshop_material_convert_weight(unit_weight, replaced_row.unit_id, material_row.unit_id);
            IF unit_weight IS NOT NULL THEN weight_source := 'REPLACED_ROW_BOM'; END IF;
            RETURN;
        END IF;
        SELECT fn_workshop_material_convert_weight(step.unit_weight, replaced_row.unit_id, material_row.unit_id),
               step.weight_source INTO unit_weight, weight_source
        FROM fn_workshop_material_unit_weight_step(replaced_row.id, p_depth + 1) step;
        IF unit_weight IS NULL THEN
            weight_source := NULL;
        ELSIF weight_source = 'BOM_AT_CLOSE' THEN
            weight_source := 'REPLACED_ROW_BOM';
        END IF;
        RETURN;
    END IF;

    unit_weight := fn_workshop_material_edge_weight(product, material_row.material_goods_id,
        material_row.material_color_id);
    IF unit_weight IS NOT NULL THEN
        weight_source := 'BOM_AT_CLOSE';
    ELSIF material_row.design_qty_snapshot IS NOT NULL THEN
        unit_weight := material_row.design_qty_snapshot;
        weight_source := 'SEGMENT_SNAPSHOT';
    END IF;
END;
$$;
