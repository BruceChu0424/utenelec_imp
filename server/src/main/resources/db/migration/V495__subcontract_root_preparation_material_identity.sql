-- Root preparation uses the original item's direct BOM materials. Preserve all
-- UUID, active-item and same-analysis boundaries, including ordinary MAKE anchors.
CREATE OR REPLACE FUNCTION fn_analysis_plan_material_matches(
    p_item_id UUID,p_material_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(
        SELECT 1 FROM production_material_analysis_items item
        JOIN production_material_analysis_materials material
          ON material.id=p_material_id AND material.analysis_id=item.analysis_id
         AND material.active=TRUE
        LEFT JOIN production_material_analysis_materials parent
          ON parent.id=item.parent_analysis_material_id
         AND parent.analysis_id=item.analysis_id
        WHERE item.id=p_item_id AND item.is_deleted=FALSE
          AND ((item.parent_analysis_material_id IS NULL
                AND material.analysis_item_id=item.id AND material.depth=1)
            OR (item.source_type IN('MAKE_COMPONENT','SUBCONTRACT_MAKE')
                AND parent.active=TRUE
                AND material.analysis_item_id=parent.analysis_item_id
                AND ((parent.node_role='ROOT_SUPPLY'
                      AND material.depth=1 AND material.parent_node_key IS NULL)
                  OR (parent.node_role<>'ROOT_SUPPLY'
                      AND material.parent_node_key=parent.node_key)))))
$$;

COMMENT ON FUNCTION fn_analysis_plan_material_matches(UUID,UUID) IS
    'Resolve original direct material UUIDs for ordinary plans and root/nested preparation anchors without duplicating a BOM subtree';
