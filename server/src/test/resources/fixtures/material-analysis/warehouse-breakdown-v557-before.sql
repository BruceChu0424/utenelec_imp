WITH dimensions AS (
    SELECT DISTINCT material.goods_id, material.color_id,
           material.unit_id
    FROM production_material_analysis_materials material
    WHERE material.analysis_id = :analysisId
      AND material.active = TRUE
      AND material.goods_id IN (SELECT unnest(CAST(string_to_array(:goodsIds, ',') AS uuid[])))
)
SELECT dimension.goods_id, dimension.color_id, dimension.unit_id,
       w.id, w.code, w.name,
       COALESCE(v.on_hand_qty,0), COALESCE(v.reserved_qty,0),
       GREATEST(COALESCE(v.available_qty,0),0),
       COALESCE(own.own_qty,0),
       GREATEST(COALESCE(g.min_qty,0),0),
       COALESCE(open_safety.open_qty,0),
       (NOT w.is_defective
        AND NOT EXISTS(SELECT 1 FROM warehouses child
            WHERE child.parent_id=w.id AND child.is_deleted=FALSE)) AS public_allowed, fn_warehouse_main_id(w.id) AS main_warehouse_id
FROM dimensions dimension
CROSS JOIN warehouses w
JOIN goods g ON g.id = dimension.goods_id
LEFT JOIN v_stock_available v
  ON v.warehouse_id = w.id
 AND v.goods_id = dimension.goods_id
 AND v.color_id IS NOT DISTINCT FROM dimension.color_id
LEFT JOIN LATERAL (
    SELECT SUM(CASE
        WHEN EXISTS (
            SELECT 1
            FROM preplan_stock_entitlement_events tracked
            WHERE tracked.stock_reservation_id = r.id
        ) THEN COALESCE((
            SELECT SUM(balance.effective_qty)
            FROM v_preplan_stock_entitlement_beneficiary_balance balance
            JOIN production_material_analysis_materials beneficiary
              ON beneficiary.id =
                 balance.beneficiary_analysis_material_id
             AND beneficiary.analysis_id =
                 balance.beneficiary_analysis_id
            WHERE balance.stock_reservation_id = r.id
              AND balance.beneficiary_analysis_id = :analysisId
              AND beneficiary.active = TRUE
        ), 0)
        WHEN r.owner_id = :analysisId
        THEN r.qty - r.consumed_qty - r.released_qty
        ELSE 0
    END) AS own_qty
    FROM stock_reservations r
    WHERE r.is_deleted = FALSE
      AND r.status = 0
      AND r.owner_type = 'PREPLAN_ANALYSIS'
      AND r.warehouse_id = w.id
      AND r.goods_id = dimension.goods_id
      AND r.color_id IS NOT DISTINCT FROM dimension.color_id
) own ON TRUE
LEFT JOIN LATERAL (
    SELECT SUM(progress.safety_future_qty)::numeric AS open_qty
    FROM preplan_supply_actions action
    JOIN v_preplan_buy_action_slice_progress progress
      ON progress.action_id = action.id
    WHERE action.status <> 'CANCELLED'
      AND progress.safety_source_valid = TRUE
      AND action.warehouse_id = w.id
      AND action.goods_id = dimension.goods_id
      AND action.color_id IS NOT DISTINCT FROM dimension.color_id
) open_safety ON TRUE
WHERE w.is_deleted = FALSE AND w.is_accountable = TRUE
ORDER BY w.code, w.id
