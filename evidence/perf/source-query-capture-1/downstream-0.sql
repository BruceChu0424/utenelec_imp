WITH current_appends AS MATERIALIZED (
    SELECT DISTINCT batch.action_id
    FROM preplan_aggregate_batches batch
    JOIN preplan_aggregate_batch_events event ON event.batch_id=batch.id
      AND event.event_type='APPEND' AND event.transaction_id=txid_current()
      AND event.resulting_version=batch.row_version
    WHERE batch.analysis_id=:id
), selected_actions AS MATERIALIZED (
    SELECT action.*,
           CASE WHEN action.route='MAKE' AND NOT EXISTS(
                    SELECT 1 FROM current_appends append WHERE append.action_id=action.id)
                THEN NULL
                WHEN fn_preplan_supply_action_growable(action.id)
                THEN action.requested_qty+action.public_surplus_qty END AS growable_order_qty
    FROM preplan_supply_actions action
    WHERE action.analysis_id=:id
      AND EXISTS(SELECT 1 FROM preplan_supply_action_allocations allocation WHERE allocation.action_id=action.id)
)
SELECT allocation.analysis_material_id, action.id,
       -- 跨路线调入（专属在途转拨 / 公共在途认领）沿用来源路线
       -- 落动作，但它冲减的是「目标行自己那条路线」的待下达量。
       -- 分桶归属与桶内已下达量都读这个 route，所以这里按目标行
       -- 已确认路线归位；来源单据类型与单号保持原样，进度链路
       -- 仍然显示真实的采购/委外单。
       CASE WHEN action.operation_type IN ('FUTURE_TRANSFER','SHARED_FUTURE_CLAIM')
            THEN COALESCE(target_material.confirmed_route, action.route)
            ELSE action.route END,
       action.status, action.external_document_type,
       action.external_document_id, action.external_document_no,
       allocation.allocated_qty,
       -- ADR-099：申请明细仍未订货(可就地改大)时给出明细当前数量。
       action.growable_order_qty
FROM preplan_supply_action_allocations allocation
JOIN selected_actions action ON action.id = allocation.action_id
JOIN production_material_analysis_materials target_material
  ON target_material.id = allocation.analysis_material_id
WHERE action.analysis_id = :id
ORDER BY action.created_at, action.id, allocation.id
