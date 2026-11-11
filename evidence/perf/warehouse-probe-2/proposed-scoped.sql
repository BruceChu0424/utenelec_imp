WITH dimensions AS MATERIALIZED (
                SELECT DISTINCT material.goods_id, material.color_id, material.unit_id
                FROM production_material_analysis_materials material
                WHERE material.analysis_id = 'ed1c28cd-39f9-442d-8c17-5ff79caf2806'::uuid AND material.active = TRUE
                  AND material.goods_id IN (SELECT unnest(CAST(string_to_array('2c0231bd-2f46-449e-b048-179f016ec353,34056ac5-4c79-4658-bfc6-daf3922a7c20,3578d869-48f2-4be6-a6d3-f2e70e220bf1,3677d46f-6afa-4b23-8a79-b853127082dc,410a3b41-42e1-4ba1-bd16-e9d227c6b77d,44cc16be-74d5-4826-9bf5-47cd17e0ebde,4a52935f-c27b-41f4-91d2-a0348a49e7ce,4c9c9228-904c-4f56-9202-aa045d3f477f,675729a6-e4d3-43ee-82a8-dfaf4348084e,6ab6fb9c-9336-4572-ac4b-f998443ab77f,6fe8c3f5-611b-44f2-9d92-6613741ec16e,7295c63f-f9ea-400b-866a-ed7f31d3f639,7402d248-abe4-440a-b160-9d297e0bb215,94cb7228-820a-4261-8feb-5c30418ee43f,a92f23d9-01bf-4c4d-bd88-c9be0edcb048,aaadcb63-3481-4629-a880-573bdef3a076,b5ac4012-e854-4b3e-b40e-83f9236845c0,bdeafa86-cfa7-4b73-b39f-e10301aface0,c39d46e0-c1f4-4c7a-851e-af99cb279a3f,d8d12be8-05dd-4a1b-a664-ef293d3cf102,dea7d222-328c-49f5-b780-d3793ff4e6f4,e431273b-bb41-47a9-a698-9a579d9a389d', ',') AS uuid[])))
            ), warehouse_facts AS MATERIALIZED (
                -- ADR-146: 分仓明细直接不列不良品仓(不良品不计入任何可用量)。
                SELECT w.id, w.code, w.name,
                       fn_warehouse_counts_as_usable(w.id) AS public_allowed,
                       fn_warehouse_main_id(w.id) AS main_warehouse_id
                FROM warehouses w
                WHERE w.is_deleted=FALSE AND w.is_accountable=TRUE AND NOT w.is_defective
            ), open_safety AS MATERIALIZED (
                SELECT action.warehouse_id, action.goods_id, action.color_id,
                       SUM(progress.safety_future_qty)::numeric AS open_qty
                FROM preplan_supply_actions action
                JOIN v_preplan_buy_action_slice_progress progress ON progress.action_id=action.id
                WHERE action.status <> 'CANCELLED'
                  AND action.safety_external_item_id IS NOT NULL
                  AND progress.safety_source_valid=TRUE
                  AND EXISTS (SELECT 1 FROM warehouse_facts warehouse WHERE warehouse.id=action.warehouse_id)
                  AND EXISTS (SELECT 1 FROM dimensions dimension
                      WHERE dimension.goods_id=action.goods_id
                        AND dimension.color_id IS NOT DISTINCT FROM action.color_id)
                GROUP BY action.warehouse_id, action.goods_id, action.color_id
            ), own_quantities AS MATERIALIZED (
 SELECT r.warehouse_id,r.goods_id,r.color_id,SUM(CASE
                    WHEN EXISTS (SELECT 1 FROM preplan_stock_entitlement_events tracked
                        WHERE tracked.stock_reservation_id=r.id)
                    THEN COALESCE((
                        SELECT SUM(balance.effective_qty)
                        FROM v_preplan_stock_entitlement_beneficiary_balance balance
                        JOIN production_material_analysis_materials beneficiary
                          ON beneficiary.id=balance.beneficiary_analysis_material_id
                         AND beneficiary.analysis_id=balance.beneficiary_analysis_id
                        WHERE balance.stock_reservation_id=r.id
                          AND balance.beneficiary_analysis_id='ed1c28cd-39f9-442d-8c17-5ff79caf2806'::uuid
                          AND beneficiary.active=TRUE
                    ),0)
                    WHEN r.owner_id='ed1c28cd-39f9-442d-8c17-5ff79caf2806'::uuid THEN r.qty-r.consumed_qty-r.released_qty
                    ELSE 0 END) AS own_qty
 FROM stock_reservations r
 WHERE r.is_deleted=FALSE AND r.status=0 AND r.owner_type='PREPLAN_ANALYSIS'
   AND EXISTS (SELECT 1 FROM warehouse_facts warehouse WHERE warehouse.id=r.warehouse_id)
   AND EXISTS (SELECT 1 FROM dimensions dimension WHERE dimension.goods_id=r.goods_id
       AND dimension.color_id IS NOT DISTINCT FROM r.color_id)
 GROUP BY r.warehouse_id,r.goods_id,r.color_id
)
            SELECT dimension.goods_id, dimension.color_id, dimension.unit_id,
                   w.id, w.code, w.name,
                   COALESCE(v.on_hand_qty,0), COALESCE(v.reserved_qty,0),
                   GREATEST(COALESCE(v.available_qty,0),0), COALESCE(own.own_qty,0),
                   GREATEST(COALESCE(g.min_qty,0),0), COALESCE(open_safety.open_qty,0),
                   w.public_allowed, w.main_warehouse_id
            FROM dimensions dimension
            CROSS JOIN warehouse_facts w
            JOIN goods g ON g.id=dimension.goods_id
            LEFT JOIN v_stock_available v
              ON v.goods_id = ANY(CAST(string_to_array('2c0231bd-2f46-449e-b048-179f016ec353,34056ac5-4c79-4658-bfc6-daf3922a7c20,3578d869-48f2-4be6-a6d3-f2e70e220bf1,3677d46f-6afa-4b23-8a79-b853127082dc,410a3b41-42e1-4ba1-bd16-e9d227c6b77d,44cc16be-74d5-4826-9bf5-47cd17e0ebde,4a52935f-c27b-41f4-91d2-a0348a49e7ce,4c9c9228-904c-4f56-9202-aa045d3f477f,675729a6-e4d3-43ee-82a8-dfaf4348084e,6ab6fb9c-9336-4572-ac4b-f998443ab77f,6fe8c3f5-611b-44f2-9d92-6613741ec16e,7295c63f-f9ea-400b-866a-ed7f31d3f639,7402d248-abe4-440a-b160-9d297e0bb215,94cb7228-820a-4261-8feb-5c30418ee43f,a92f23d9-01bf-4c4d-bd88-c9be0edcb048,aaadcb63-3481-4629-a880-573bdef3a076,b5ac4012-e854-4b3e-b40e-83f9236845c0,bdeafa86-cfa7-4b73-b39f-e10301aface0,c39d46e0-c1f4-4c7a-851e-af99cb279a3f,d8d12be8-05dd-4a1b-a664-ef293d3cf102,dea7d222-328c-49f5-b780-d3793ff4e6f4,e431273b-bb41-47a9-a698-9a579d9a389d', ',') AS uuid[]))
             AND v.warehouse_id=w.id AND v.goods_id=dimension.goods_id
             AND v.color_id IS NOT DISTINCT FROM dimension.color_id
            LEFT JOIN own_quantities own
              ON own.warehouse_id=w.id AND own.goods_id=dimension.goods_id
             AND own.color_id IS NOT DISTINCT FROM dimension.color_id
            LEFT JOIN open_safety
              ON open_safety.warehouse_id=w.id AND open_safety.goods_id=dimension.goods_id
             AND open_safety.color_id IS NOT DISTINCT FROM dimension.color_id
            ORDER BY w.code, w.id;
