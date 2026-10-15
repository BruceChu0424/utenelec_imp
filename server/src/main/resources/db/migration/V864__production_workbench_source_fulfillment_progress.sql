-- Planning and fulfillment are separate facts. Qualified root-output handoffs
-- (including covered stock) do not need a work order; a submitted plan or an
-- exact pending procurement promise is arranged, but is not finished output.
-- Never use available public stock or an unclaimed future candidate as coverage.
-- Exact ownership is accounted before the ordinary formal-reservation pool.
-- FORMALIZE transfers the same quantity out of the beneficiary balance: these
-- two states are disjoint. Retain consumed formal material, and net RESTORE.
CREATE FUNCTION fn_production_workbench_material_owned_coverage(p_analysis UUID)
RETURNS TABLE(analysis_id UUID,material_id UUID,reservation_id UUID,demand_id UUID,
              source_child_id UUID,qty numeric)
LANGUAGE sql STABLE AS $$
    WITH raw AS (
        SELECT balance.beneficiary_analysis_id AS analysis_id,
               balance.beneficiary_analysis_material_id AS material_id,
               reservation.id AS reservation_id, NULL::uuid AS demand_id,
               COALESCE(exact.make_source_analysis_item_id,
                 CASE WHEN action.external_document_type='PREPLAN_MAKE_TASK'
                      THEN action.external_document_id END) AS source_child_id,
               LEAST(balance.effective_qty,
                 GREATEST(reservation.qty-reservation.consumed_qty-reservation.released_qty,0)) AS qty,
               GREATEST(reservation.qty-reservation.consumed_qty-reservation.released_qty,0) AS capacity
        FROM v_preplan_stock_entitlement_beneficiary_balance balance
        JOIN stock_reservations reservation ON reservation.id=balance.stock_reservation_id
          AND reservation.status=0 AND NOT reservation.is_deleted
        JOIN preplan_analysis_stock_exact_pegs exact ON exact.stock_reservation_id=reservation.id
        LEFT JOIN preplan_supply_action_allocations allocation ON allocation.id=exact.supply_action_allocation_id
        LEFT JOIN preplan_supply_actions action ON action.id=allocation.action_id
        JOIN production_material_analysis_materials material ON material.id=balance.beneficiary_analysis_material_id
          AND material.analysis_id=balance.beneficiary_analysis_id AND material.active
          AND material.goods_id=reservation.goods_id
          AND material.color_id IS NOT DISTINCT FROM reservation.color_id
        WHERE balance.beneficiary_analysis_id=p_analysis
          AND fn_preplan_reservation_has_qualified_origin(reservation.id)
        UNION ALL
        SELECT formal.analysis_id, formal.material_id, target.id, target.demand_id,
               formal.source_child_id, formal.qty, GREATEST(target.qty-target.released_qty,0)
        FROM (
          SELECT event.beneficiary_analysis_id AS analysis_id,
                 event.beneficiary_analysis_material_id AS material_id,
                 event.target_stock_reservation_id,
                 COALESCE(exact.make_source_analysis_item_id,
                   CASE WHEN action.external_document_type='PREPLAN_MAKE_TASK'
                        THEN action.external_document_id END) AS source_child_id,
                 SUM(GREATEST(event.qty-COALESCE((SELECT SUM(counter.qty)
                     FROM preplan_stock_entitlement_events counter
                     WHERE counter.event_type='RESTORE' AND counter.counter_event_id=event.id),0),0)) AS qty
          FROM preplan_stock_entitlement_events event
          JOIN preplan_analysis_stock_exact_pegs exact ON exact.stock_reservation_id=event.stock_reservation_id
          LEFT JOIN preplan_supply_action_allocations allocation ON allocation.id=exact.supply_action_allocation_id
          LEFT JOIN preplan_supply_actions action ON action.id=allocation.action_id
          WHERE event.event_type='FORMALIZE' AND event.beneficiary_analysis_id=p_analysis
            AND fn_preplan_reservation_has_qualified_origin(event.stock_reservation_id)
          GROUP BY event.beneficiary_analysis_id,event.beneficiary_analysis_material_id,
                   event.target_stock_reservation_id,exact.make_source_analysis_item_id,
                   action.external_document_type,action.external_document_id
        ) formal
        JOIN stock_reservations target ON target.id=formal.target_stock_reservation_id AND NOT target.is_deleted
        JOIN production_material_demands demand ON demand.id=target.demand_id AND NOT demand.is_deleted
          AND demand.status NOT IN ('RELEASED','REVERSED')
        JOIN production_plans plan ON plan.id=demand.plan_id AND plan.status=1
          AND NOT plan.is_deleted AND NOT plan.is_canceled AND plan.material_analysis_id=formal.analysis_id
        JOIN production_material_analysis_items source ON source.id=plan.material_analysis_item_id AND NOT source.is_deleted
        LEFT JOIN production_material_analysis_materials parent ON parent.id=source.parent_analysis_material_id
          AND parent.analysis_id=source.analysis_id
        JOIN production_material_analysis_materials material ON material.id=formal.material_id AND material.active
          AND material.analysis_id=formal.analysis_id
          AND (material.goods_id,material.color_id,material.unit_id)
              IS NOT DISTINCT FROM (demand.goods_id,demand.color_id,demand.unit_id)
          -- Inline of fn_analysis_plan_material_matches(source.id,material.id) in its
          -- post-V798 shape; keep in sync with the surviving function definition.
          AND (
            (source.parent_analysis_material_id IS NULL
               AND material.analysis_item_id=source.id AND material.depth=1)
            OR (source.source_type='MAKE_COMPONENT'
               AND parent.active
               AND material.analysis_item_id=parent.analysis_item_id
               AND ((parent.node_role='ROOT_SUPPLY' AND material.depth=1
                       AND material.parent_node_key IS NULL)
                 OR (parent.node_role<>'ROOT_SUPPLY'
                       AND material.parent_node_key=parent.node_key))))
    ), sliced AS (
        SELECT raw.*, COALESCE(SUM(qty) OVER (PARTITION BY reservation_id
            ORDER BY material_id,source_child_id NULLS FIRST
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS prior_qty
        FROM raw
    )
    SELECT analysis_id,material_id,reservation_id,demand_id,source_child_id,
           LEAST(qty,GREATEST(capacity-prior_qty,0))::numeric AS qty
    FROM sliced WHERE qty>0;
$$;

-- One frozen demand can represent several distinct BOM paths of the same SKU.
-- Slice its retained gross responsibility once, in the service's stable path
-- order. Completed batches remain responsibility; retired split parents do not.
-- The view body is mirrored by fn_production_workbench_frozen_material_scopes
-- below with the analysis predicate folded to the driving plan scan; keep the
-- two in sync. Window functions block predicate pushdown, so the credits
-- trigger path must call the function, not filter this view.
CREATE VIEW v_production_workbench_frozen_material_scopes AS
WITH candidates AS (
    SELECT plan.material_analysis_id AS analysis_id,demand.id AS demand_id,
           material.id AS material_id,material.path,material.node_key,
           GREATEST(COALESCE(demand.required_qty,0)-COALESCE(demand.released_qty,0),0) AS retained_qty,
           COALESCE((SELECT SUM(owned.qty) FROM fn_production_workbench_material_owned_coverage(plan.material_analysis_id) owned
             WHERE owned.demand_id=demand.id AND owned.material_id=material.id),0) AS pinned_qty,
           COUNT(*) OVER (PARTITION BY demand.id) AS member_count,
           fn_material_analysis_edge_required(
             (COALESCE(demand.required_for_product_qty,segment.planned_qty,output.qty,0)
               +CASE WHEN segment.split_root_segment_id IS NOT NULL THEN segment.split_start_qty ELSE 0 END)
               * COALESCE((demand.consumption_snapshot->>'productUnitRate')::numeric,segment.product_unit_rate,output.unit_rate,1)
               * COALESCE(material.parent_per_product_qty,1)
               / COALESCE(NULLIF(parent.per_product_qty,0),NULLIF(root.per_product_qty,0),1),
             material.bom_qty,material.consumption_basis,material.basis_output_qty,material.allow_partial_package)
             -fn_material_analysis_edge_required(
               (CASE WHEN segment.split_root_segment_id IS NOT NULL THEN segment.split_start_qty ELSE 0 END)
                 * COALESCE((demand.consumption_snapshot->>'productUnitRate')::numeric,segment.product_unit_rate,output.unit_rate,1)
                 * COALESCE(material.parent_per_product_qty,1)
                 / COALESCE(NULLIF(parent.per_product_qty,0),NULLIF(root.per_product_qty,0),1),
               material.bom_qty,material.consumption_basis,material.basis_output_qty,material.allow_partial_package) AS curve_qty,
           fn_preplan_aggregate_source_capacity(material.id) AS live_qty
    FROM production_material_demands demand
    JOIN production_plans plan ON plan.id=demand.plan_id AND plan.status=1
      AND NOT plan.is_deleted AND NOT plan.is_canceled
    JOIN production_material_analysis_items source ON source.id=plan.material_analysis_item_id
      AND source.analysis_id=plan.material_analysis_id AND NOT source.is_deleted
    LEFT JOIN production_material_analysis_materials parent ON parent.id=source.parent_analysis_material_id
    LEFT JOIN production_material_analysis_materials root ON root.id=source.root_material_id
    LEFT JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id
    LEFT JOIN LATERAL (
      SELECT SUM(item.qty) AS qty,MAX(item.unit_rate) AS unit_rate
      FROM production_plan_items item WHERE item.plan_id=plan.id AND NOT item.is_deleted
        AND (demand.source_plan_item_id IS NULL OR item.id=demand.source_plan_item_id)
    ) output ON TRUE
    JOIN production_material_analysis_materials material ON material.analysis_id=plan.material_analysis_id AND material.active
      AND (material.goods_id,material.color_id,material.unit_id)
          IS NOT DISTINCT FROM (demand.goods_id,demand.color_id,demand.unit_id)
      AND fn_analysis_plan_material_matches(source.id,material.id)
    WHERE NOT demand.is_deleted AND demand.status NOT IN ('RELEASED','REVERSED')
      AND (demand.execution_segment_id IS NULL OR (segment.id IS NOT NULL AND NOT segment.is_deleted
           AND segment.status NOT IN ('CANCELLED','REVERSED')))
), caps AS (
    SELECT candidates.*,
           CASE WHEN member_count=1 THEN retained_qty
                ELSE GREATEST(COALESCE(curve_qty,live_qty,0),pinned_qty) END AS capacity,
           SUM(pinned_qty) OVER (PARTITION BY demand_id) AS pinned_total
    FROM candidates
), slots AS (
    SELECT caps.*,COALESCE(SUM(GREATEST(capacity-pinned_qty,0)) OVER (PARTITION BY demand_id
        ORDER BY path,node_key,material_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS prior_capacity
    FROM caps
)
SELECT analysis_id,demand_id,material_id,path,node_key,
       (pinned_qty+LEAST(GREATEST(capacity-pinned_qty,0),
         GREATEST(retained_qty-pinned_total-prior_capacity,0)))::numeric AS qty
FROM slots;

CREATE FUNCTION fn_production_workbench_frozen_material_scopes(p_analysis UUID)
RETURNS TABLE(analysis_id UUID,demand_id UUID,material_id UUID,path TEXT,node_key TEXT,qty numeric)
LANGUAGE sql STABLE AS $$
    WITH pinned AS (
        SELECT owned.demand_id,owned.material_id,SUM(owned.qty) AS qty
        FROM fn_production_workbench_material_owned_coverage(p_analysis) owned
        GROUP BY owned.demand_id,owned.material_id
    ), candidates AS (
        SELECT plan.material_analysis_id AS analysis_id,demand.id AS demand_id,
               material.id AS material_id,material.path,material.node_key,
               GREATEST(COALESCE(demand.required_qty,0)-COALESCE(demand.released_qty,0),0) AS retained_qty,
               COALESCE(pinned.qty,0) AS pinned_qty,
               COUNT(*) OVER (PARTITION BY demand.id) AS member_count,
               fn_material_analysis_edge_required(
                 (COALESCE(demand.required_for_product_qty,segment.planned_qty,output.qty,0)
                   +CASE WHEN segment.split_root_segment_id IS NOT NULL THEN segment.split_start_qty ELSE 0 END)
                   * COALESCE((demand.consumption_snapshot->>'productUnitRate')::numeric,segment.product_unit_rate,output.unit_rate,1)
                   * COALESCE(material.parent_per_product_qty,1)
                   / COALESCE(NULLIF(parent.per_product_qty,0),NULLIF(root.per_product_qty,0),1),
                 material.bom_qty,material.consumption_basis,material.basis_output_qty,material.allow_partial_package)
                 -fn_material_analysis_edge_required(
                   (CASE WHEN segment.split_root_segment_id IS NOT NULL THEN segment.split_start_qty ELSE 0 END)
                     * COALESCE((demand.consumption_snapshot->>'productUnitRate')::numeric,segment.product_unit_rate,output.unit_rate,1)
                     * COALESCE(material.parent_per_product_qty,1)
                     / COALESCE(NULLIF(parent.per_product_qty,0),NULLIF(root.per_product_qty,0),1),
                   material.bom_qty,material.consumption_basis,material.basis_output_qty,material.allow_partial_package) AS curve_qty,
               GREATEST(COALESCE(material.required_qty,0)+COALESCE(capacity.qty_sum,0),
                        COALESCE(capacity.cap_max,0)) AS live_qty
        FROM production_material_demands demand
        JOIN production_plans plan ON plan.id=demand.plan_id AND plan.status=1
          AND NOT plan.is_deleted AND NOT plan.is_canceled
          AND plan.material_analysis_id=p_analysis
        JOIN production_material_analysis_items source ON source.id=plan.material_analysis_item_id
          AND source.analysis_id=plan.material_analysis_id AND NOT source.is_deleted
        LEFT JOIN production_material_analysis_materials parent ON parent.id=source.parent_analysis_material_id
          AND parent.analysis_id=source.analysis_id
        LEFT JOIN production_material_analysis_materials root ON root.id=source.root_material_id
        LEFT JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id
        LEFT JOIN LATERAL (
          SELECT SUM(item.qty) AS qty,MAX(item.unit_rate) AS unit_rate
          FROM production_plan_items item WHERE item.plan_id=plan.id AND NOT item.is_deleted
            AND (demand.source_plan_item_id IS NULL OR item.id=demand.source_plan_item_id)
        ) output ON TRUE
        JOIN production_material_analysis_materials material ON material.analysis_id=plan.material_analysis_id AND material.active
          AND (material.goods_id,material.color_id,material.unit_id)
              IS NOT DISTINCT FROM (demand.goods_id,demand.color_id,demand.unit_id)
          -- Inline of fn_analysis_plan_material_matches(source.id,material.id) in its
          -- post-V798 shape (the retired SUBCONTRACT_MAKE value no longer exists);
          -- keep in sync with the surviving function definition.
          AND (
            (source.parent_analysis_material_id IS NULL
               AND material.analysis_item_id=source.id AND material.depth=1)
            OR (source.source_type='MAKE_COMPONENT'
               AND parent.active
               AND material.analysis_item_id=parent.analysis_item_id
               AND ((parent.node_role='ROOT_SUPPLY' AND material.depth=1
                       AND material.parent_node_key IS NULL)
                 OR (parent.node_role<>'ROOT_SUPPLY'
                       AND material.parent_node_key=parent.node_key))))
        LEFT JOIN LATERAL (
          SELECT SUM(fn_preplan_aggregate_alias_qty(alias.id))
                   FILTER (WHERE fn_preplan_aggregate_alias_identity_valid(alias.id)) AS qty_sum,
                 MAX(fn_preplan_aggregate_alias_source_capacity(alias.id))
                   FILTER (WHERE fn_preplan_aggregate_alias_identity_valid(alias.id)) AS cap_max
          FROM preplan_aggregate_material_aliases alias WHERE alias.source_material_id=material.id
        ) capacity ON TRUE
        LEFT JOIN pinned ON pinned.demand_id=demand.id AND pinned.material_id=material.id
        WHERE NOT demand.is_deleted AND demand.status NOT IN ('RELEASED','REVERSED')
          AND (demand.execution_segment_id IS NULL OR (segment.id IS NOT NULL AND NOT segment.is_deleted
               AND segment.status NOT IN ('CANCELLED','REVERSED')))
    ), caps AS (
        SELECT candidates.*,
               CASE WHEN member_count=1 THEN retained_qty
                    ELSE GREATEST(COALESCE(curve_qty,live_qty,0),pinned_qty) END AS capacity,
               SUM(pinned_qty) OVER (PARTITION BY demand_id) AS pinned_total
        FROM candidates
    ), slots AS (
        SELECT caps.*,COALESCE(SUM(GREATEST(capacity-pinned_qty,0)) OVER (PARTITION BY demand_id
            ORDER BY path,node_key,material_id
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS prior_capacity
        FROM caps
    )
    SELECT analysis_id,demand_id,material_id,path,node_key,
           (pinned_qty+LEAST(GREATEST(capacity-pinned_qty,0),
             GREATEST(retained_qty-pinned_total-prior_capacity,0)))::numeric AS qty
    FROM slots;
$$;

-- A warehouse custody successor retains its direct source allocation. It does
-- not create another FORMALIZE event. Keep that source identity when allocating
-- the retained material, including pending custody whose demand is owner_id.
CREATE FUNCTION fn_production_workbench_formal_stock_pools(p_analysis UUID)
RETURNS TABLE(demand_id UUID,analysis_id UUID,source_child_id UUID,material_id UUID,qty numeric)
LANGUAGE sql STABLE AS $$
    WITH custody AS (
        SELECT demand.id AS demand_id,plan.material_analysis_id AS analysis_id,
               held.id AS reservation_id,allocation.id AS allocation_id,
               origin.material_analysis_item_id AS source_child_id,
               CASE WHEN source.analysis_id=plan.material_analysis_id
                      AND fn_analysis_plan_material_matches(target.id,source.parent_analysis_material_id)
                    THEN source.parent_analysis_material_id END AS material_id,
               allocation.effective_qty AS qty,GREATEST(held.qty-held.released_qty,0) AS capacity,
               COALESCE(SUM(allocation.effective_qty) OVER (PARTITION BY held.id
                 ORDER BY allocation.allocation_no ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS prior_qty
        FROM stock_reservations held
        JOIN production_material_demands demand ON demand.id=COALESCE(held.demand_id,
          CASE WHEN held.owner_type='WORKSHOP_CUSTODY' THEN held.owner_id END)
          AND NOT demand.is_deleted AND demand.status NOT IN('RELEASED','REVERSED')
        JOIN production_plans plan ON plan.id=demand.plan_id AND plan.status=1
          AND NOT plan.is_deleted AND NOT plan.is_canceled
          AND plan.material_analysis_id=p_analysis
        JOIN production_material_analysis_items target ON target.id=plan.material_analysis_item_id AND NOT target.is_deleted
        JOIN v_workshop_direct_source_allocations allocation ON allocation.stock_reservation_id=held.id AND allocation.effective_qty>0
        JOIN production_workshop_direct_transfer_items transfer ON transfer.id=allocation.transfer_item_id
        JOIN production_daily_report_items report ON report.id=transfer.source_report_item_id
        JOIN production_plan_items item ON item.id=report.plan_item_id AND NOT item.is_deleted
        JOIN production_plans origin ON origin.id=item.plan_id
        LEFT JOIN production_material_analysis_items source ON source.id=origin.material_analysis_item_id
        WHERE held.source_doc_type='WORKSHOP_RETURN_CUSTODY' AND NOT held.is_deleted
          AND held.owner_type IN('PRODUCTION_MATERIAL_DEMAND','WORKSHOP_CUSTODY')
          AND EXISTS(SELECT 1 FROM stock_document_items receipt JOIN stock_documents document ON document.id=receipt.doc_id
            WHERE receipt.source_daily_report_item_id=report.id AND receipt.bill_type='FINISHED_IN'
              AND document.doc_type='FINISHED_IN' AND document.status=1 AND NOT document.is_deleted AND NOT receipt.is_deleted)
    )
    SELECT demand_id,analysis_id,source_child_id,material_id,
           LEAST(qty,GREATEST(capacity-prior_qty,0))::numeric AS qty FROM custody
    UNION ALL
    SELECT demand.id,plan.material_analysis_id,NULL::uuid,NULL::uuid,
           SUM(GREATEST(reservation.qty-reservation.released_qty-COALESCE((
             SELECT SUM(GREATEST(formal.qty-COALESCE((SELECT SUM(restored.qty)
               FROM preplan_stock_entitlement_events restored WHERE restored.event_type='RESTORE'
                 AND restored.counter_event_id=formal.id),0),0))
             FROM preplan_stock_entitlement_events formal WHERE formal.event_type='FORMALIZE'
               AND formal.target_stock_reservation_id=reservation.id),0),0))
    FROM production_material_demands demand
    JOIN production_plans plan ON plan.id=demand.plan_id AND plan.status=1 AND NOT plan.is_deleted AND NOT plan.is_canceled
      AND plan.material_analysis_id=p_analysis
    JOIN production_material_analysis_items source ON source.id=plan.material_analysis_item_id AND NOT source.is_deleted
    JOIN stock_reservations reservation ON reservation.demand_id=demand.id
      AND reservation.owner_type='PRODUCTION_MATERIAL_DEMAND' AND NOT reservation.requires_qualified_origin
      AND NOT reservation.is_deleted AND reservation.source_doc_type IS DISTINCT FROM 'WORKSHOP_RETURN_CUSTODY'
    WHERE NOT demand.is_deleted AND demand.status NOT IN('RELEASED','REVERSED')
    GROUP BY demand.id,plan.material_analysis_id;
$$;

-- Row triggers (plan-link insert, plan lifecycle) recompute analysis status
-- synchronously, so this function must stay single-pass: the frozen scopes,
-- owned coverage and pending supply views are materialized once per call into
-- JSONB snapshots and every loop below reads only those snapshots. Re-querying
-- the views per material, per demand or per component child turned one trigger
-- fire into seconds of repeated fn_analysis_plan_material_matches calls.
CREATE FUNCTION fn_production_workbench_component_credits(p_analysis UUID)
RETURNS TABLE(analysis_item_id UUID,fulfillment_credit numeric,schedule_credit numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE row RECORD; child RECORD; rec RECORD; pool NUMERIC; headroom NUMERIC; take NUMERIC;
        gross JSONB:='{}'; used JSONB:='{}'; source_used JSONB:='{}';
        scopes_by_demand JSONB:='{}'; scope_sum_by_material JSONB:='{}';
        owned_by_material JSONB:='{}'; owned_by_demand_material JSONB:='{}';
        owned_by_material_child JSONB:='{}'; pending_by_material JSONB:='{}';
        demand_key TEXT; material_key TEXT; child_key TEXT;
        actual NUMERIC; pending NUMERIC; responsibility NUMERIC;
BEGIN
    -- No active component child means the table below has no rows at all;
    -- short-circuit before materializing snapshots for trigger-time callers.
    IF NOT EXISTS(SELECT 1 FROM production_material_analysis_items guard
                  WHERE guard.analysis_id=p_analysis AND guard.source_type='MAKE_COMPONENT'
                    AND NOT guard.is_deleted AND guard.requested_qty>0) THEN
        RETURN;
    END IF;
    FOR rec IN
      SELECT scope.demand_id,scope.material_id,scope.qty
      FROM fn_production_workbench_frozen_material_scopes(p_analysis) scope
      WHERE scope.analysis_id=p_analysis
      ORDER BY scope.demand_id,scope.path,scope.node_key,scope.material_id
    LOOP
      demand_key:=rec.demand_id::text; material_key:=rec.material_id::text;
      scopes_by_demand:=jsonb_set(scopes_by_demand,ARRAY[demand_key],
        COALESCE(scopes_by_demand->demand_key,'[]'::jsonb)||jsonb_build_array(
          jsonb_build_object('material_id',material_key,'qty',rec.qty)));
      scope_sum_by_material:=jsonb_set(scope_sum_by_material,ARRAY[material_key],
        to_jsonb(COALESCE((scope_sum_by_material->>material_key)::numeric,0)+rec.qty));
    END LOOP;
    FOR rec IN
      SELECT owned.demand_id,owned.material_id,owned.source_child_id,owned.qty
      FROM fn_production_workbench_material_owned_coverage(p_analysis) owned
      WHERE owned.analysis_id=p_analysis
    LOOP
      material_key:=rec.material_id::text;
      owned_by_material:=jsonb_set(owned_by_material,ARRAY[material_key],
        to_jsonb(COALESCE((owned_by_material->>material_key)::numeric,0)+rec.qty));
      IF rec.demand_id IS NOT NULL THEN
        demand_key:=rec.demand_id::text||':'||material_key;
        owned_by_demand_material:=jsonb_set(owned_by_demand_material,ARRAY[demand_key],
          to_jsonb(COALESCE((owned_by_demand_material->>demand_key)::numeric,0)+rec.qty));
      END IF;
      child_key:=COALESCE(rec.source_child_id::text,'');
      owned_by_material_child:=jsonb_set(owned_by_material_child,ARRAY[material_key,child_key],
        to_jsonb(COALESCE((owned_by_material_child->material_key->>child_key)::numeric,0)+rec.qty));
    END LOOP;
    FOR rec IN
      SELECT supply.material_id,SUM(supply.qty) AS qty FROM (
        SELECT allocation.analysis_material_id AS material_id,GREATEST(CASE
          WHEN fn_preplan_action_has_future_transfer(action.id) OR fn_preplan_action_has_shared_claim_history(action.id)
            THEN fn_preplan_future_allocation_pending_qty(allocation.id)
          WHEN action.operation_type='SHARED_FUTURE_CLAIM' THEN fn_preplan_shared_allocation_pending_qty(allocation.id)
          ELSE fn_preplan_allocation_admitted_qty(allocation.id)-fn_preplan_allocation_effective_exact_qty(allocation.id)
            -COALESCE((SELECT SUM(CASE WHEN output.event_kind='FULFILL' THEN output.qty_base ELSE -output.qty_base END)
                FROM preplan_root_output_events output JOIN preplan_analysis_stock_exact_pegs exact
                ON exact.stock_reservation_id=output.source_reservation_id WHERE exact.supply_action_allocation_id=allocation.id),0)
          END,0) AS qty
        FROM preplan_supply_action_allocations allocation JOIN preplan_supply_actions action ON action.id=allocation.action_id
        WHERE allocation.analysis_id=p_analysis AND action.status IN('OPEN','CREATED','IN_PROGRESS')
          AND action.external_document_type<>'PREPLAN_MAKE_TASK'
        UNION ALL SELECT claim.target_material_id,fn_preplan_make_public_claim_pending_qty(claim.id)
        FROM preplan_make_public_claims claim WHERE claim.target_analysis_id=p_analysis
      ) supply GROUP BY supply.material_id
    LOOP
      pending_by_material:=jsonb_set(pending_by_material,ARRAY[rec.material_id::text],to_jsonb(rec.qty));
    END LOOP;
    FOR row IN
      SELECT material.id,
             GREATEST(COALESCE(material.required_qty,0)+COALESCE(capacity.qty_sum,0),
                      COALESCE(capacity.cap_max,0),
                      COALESCE((scope_sum_by_material->>material.id::text)::numeric,0)) AS qty
      FROM production_material_analysis_materials material
      LEFT JOIN LATERAL (
          SELECT SUM(fn_preplan_aggregate_alias_qty(alias.id))
                   FILTER (WHERE fn_preplan_aggregate_alias_identity_valid(alias.id)) AS qty_sum,
                 MAX(fn_preplan_aggregate_alias_source_capacity(alias.id))
                   FILTER (WHERE fn_preplan_aggregate_alias_identity_valid(alias.id)) AS cap_max
          FROM preplan_aggregate_material_aliases alias WHERE alias.source_material_id=material.id
      ) capacity ON TRUE
      WHERE material.analysis_id=p_analysis AND material.active
    LOOP
      gross:=jsonb_set(gross,ARRAY[row.id::text],to_jsonb(row.qty));
    END LOOP;
    -- Exact beneficiaries (including a child's own output) occupy their gross
    -- slots first. The ordinary remainder then consumes each demand only once.
    FOR row IN
      SELECT stock.demand_id AS id,stock.source_child_id,stock.material_id,SUM(stock.qty) AS qty
      FROM fn_production_workbench_formal_stock_pools(p_analysis) stock WHERE stock.analysis_id=p_analysis
      GROUP BY stock.demand_id,stock.source_child_id,stock.material_id
      ORDER BY stock.demand_id,stock.source_child_id NULLS LAST,stock.material_id
    LOOP
      pool:=row.qty;
      FOR child IN SELECT * FROM jsonb_to_recordset(COALESCE(scopes_by_demand->row.id::text,'[]'::jsonb))
          AS scope(material_id text,qty numeric)
      LOOP
        IF row.material_id IS NOT NULL AND child.material_id IS DISTINCT FROM row.material_id::text THEN
          CONTINUE;
        END IF;
        headroom:=GREATEST(COALESCE((gross->>child.material_id)::numeric,0)
          -COALESCE((used->>child.material_id)::numeric,0)
          -COALESCE((owned_by_material->>child.material_id)::numeric,0),0);
        take:=LEAST(pool,headroom,GREATEST(child.qty-COALESCE((
          owned_by_demand_material->>(row.id::text||':'||child.material_id))::numeric,0),0));
        IF take>0 THEN
          used:=jsonb_set(used,ARRAY[child.material_id],to_jsonb(
            COALESCE((used->>child.material_id)::numeric,0)+take));
          IF row.source_child_id IS NOT NULL THEN
            source_used:=jsonb_set(source_used,ARRAY[child.material_id||':'||row.source_child_id::text],to_jsonb(
              COALESCE((source_used->>(child.material_id||':'||row.source_child_id::text))::numeric,0)+take));
          END IF;
          pool:=pool-take;
        END IF;
      END LOOP;
    END LOOP;
    FOR child IN SELECT item.* FROM production_material_analysis_items item
      WHERE item.analysis_id=p_analysis AND item.source_type='MAKE_COMPONENT' AND NOT item.is_deleted
        AND item.requested_qty>0
    LOOP
      WITH members AS (
        SELECT child.parent_analysis_material_id AS id
        UNION
        SELECT allocation.analysis_material_id FROM preplan_supply_action_allocations allocation
        JOIN preplan_supply_actions action ON action.id=allocation.action_id AND action.status<>'CANCELLED'
          AND action.external_document_type='PREPLAN_MAKE_TASK' AND action.external_document_id=child.id
        WHERE allocation.analysis_id=p_analysis
      ), eligible AS (
        SELECT material.id FROM members JOIN production_material_analysis_materials material ON material.id=members.id
          AND material.analysis_id=p_analysis AND material.active
          AND (material.goods_id,material.color_id,material.unit_id)
              IS NOT DISTINCT FROM (child.goods_id,child.color_id,child.unit_id)
      ), supplements AS (
        SELECT supplement.reallocation_id,SUM(supplement.qty) AS qty
        FROM preplan_reallocation_make_supplements supplement
        WHERE supplement.child_analysis_item_id=child.id
          AND supplement.source_analysis_material_id IN(SELECT id FROM eligible)
        GROUP BY supplement.reallocation_id
      ), yielded_own_output AS (
        SELECT event.reallocation_id,SUM(GREATEST(event.qty-COALESCE((SELECT SUM(restored.qty)
            FROM preplan_stock_entitlement_events restored WHERE restored.event_type='RESTORE'
              AND restored.counter_event_id=event.id),0),0)) AS qty
        FROM preplan_stock_entitlement_events event
        JOIN preplan_analysis_stock_exact_pegs exact ON exact.stock_reservation_id=event.stock_reservation_id
        LEFT JOIN preplan_supply_action_allocations allocation ON allocation.id=exact.supply_action_allocation_id
        LEFT JOIN preplan_supply_actions action ON action.id=allocation.action_id
        WHERE event.event_type='REALLOCATE_OUT' AND event.beneficiary_analysis_id=p_analysis
          AND event.beneficiary_analysis_material_id IN(SELECT id FROM eligible)
          AND COALESCE(exact.make_source_analysis_item_id,
            CASE WHEN action.external_document_type='PREPLAN_MAKE_TASK' THEN action.external_document_id END)=child.id
        GROUP BY event.reallocation_id
      )
      SELECT COALESCE(SUM(COALESCE((gross->>eligible.id::text)::numeric,0)),0)
        +COALESCE((SELECT SUM(LEAST(supplements.qty,yielded.qty)) FROM supplements
          JOIN yielded_own_output yielded ON yielded.reallocation_id=supplements.reallocation_id),0),
        COALESCE(SUM(GREATEST(COALESCE((used->>eligible.id::text)::numeric,0)
          -COALESCE((source_used->>(eligible.id::text||':'||child.id::text))::numeric,0),0)+GREATEST(
          COALESCE((owned_by_material->>eligible.id::text)::numeric,0)
          -COALESCE((owned_by_material_child->eligible.id::text->>child.id::text)::numeric,0),0)),0),
        COALESCE(SUM(COALESCE((pending_by_material->>eligible.id::text)::numeric,0)),0)
      INTO responsibility,actual,pending FROM eligible;
      analysis_item_id:=child.id;
      -- Q is already net of original stock/pending. Only coverage beyond the
      -- non-child gross budget can replace this child's remaining obligation.
      -- Q already includes V568 supplements. Yielded OTHER stock falls out of S
      -- and does not add gross demand. Yielded OWN output remains in historical
      -- finished_qty, so only that exact net share needs a compensating budget.
      -- The supplement alone, or its output-admission ceiling, is not that proof.
      fulfillment_credit:=GREATEST(actual-GREATEST(responsibility-child.requested_qty,0),0);
      schedule_credit:=GREATEST(actual+pending-GREATEST(responsibility-child.requested_qty,0),0);
      RETURN NEXT;
    END LOOP;
END;
$$;

CREATE VIEW v_production_analysis_workbench_item_progress AS
WITH component_credits AS (
    SELECT analysis.analysis_id,credit.*
    FROM (SELECT DISTINCT analysis_id FROM production_material_analysis_items
          WHERE source_type='MAKE_COMPONENT' AND NOT is_deleted AND requested_qty>0) analysis
    CROSS JOIN LATERAL fn_production_workbench_component_credits(analysis.analysis_id) credit
)
SELECT item.analysis_id, item.id AS analysis_item_id,
       item.goods_id, item.color_id, item.unit_id,
       GREATEST(item.requested_qty - item.submitted_qty - item.approved_qty
                - item.root_fulfilled_qty - CASE WHEN item.source_type='MAKE_COMPONENT'
                  THEN COALESCE(component_credits.schedule_credit,0)
                  ELSE COALESCE(pending.qty,0)/COALESCE(NULLIF(root.per_product_qty,0),1) END, 0)::numeric
           AS remaining_schedule_qty,
       GREATEST(item.requested_qty - item.root_fulfilled_qty
                - COALESCE(finished.qty, 0) - COALESCE(component_credits.fulfillment_credit,0), 0)::numeric
           AS remaining_fulfillment_qty
FROM production_material_analysis_items item
LEFT JOIN production_material_analysis_materials root
  ON root.id = item.root_material_id AND root.active
LEFT JOIN production_material_analysis_materials parent
  ON parent.id = item.parent_analysis_material_id AND parent.active
LEFT JOIN component_credits ON component_credits.analysis_id=item.analysis_id AND component_credits.analysis_item_id=item.id
LEFT JOIN LATERAL (
    -- The plan's public output and excess output do not fulfill its private
    -- analysis source. Read approved physical receipts in the frozen unit,
    -- capped by this source's private plan-link budget (V694/V722 authority).
    SELECT SUM(GREATEST(LEAST(link.submitted_qty,
                   GREATEST(plan_item.qty - COALESCE(batch_action.public_surplus_qty
                       / COALESCE(plan_item.unit_rate, 1), link.public_surplus_qty, 0), 0),
                   COALESCE(received.qty, 0) / COALESCE(plan_item.unit_rate, 1)), 0)) AS qty
    FROM production_plans plan
    JOIN production_plan_items plan_item
      ON plan_item.plan_id = plan.id AND NOT plan_item.is_deleted
    JOIN production_material_analysis_plan_links link
      ON link.plan_id = plan.id AND link.analysis_id = item.analysis_id
     AND link.analysis_item_id = item.id AND link.allocation_status = 'APPROVED'
    LEFT JOIN preplan_aggregate_batches batch ON batch.plan_id = plan.id AND batch.route = 'MAKE'
    LEFT JOIN preplan_supply_actions batch_action
      ON batch_action.id = batch.action_id AND batch_action.status <> 'CANCELLED'
    LEFT JOIN LATERAL (
        SELECT SUM(output.base_qty) AS qty
        FROM stock_document_items output
        JOIN stock_documents document ON document.id = output.doc_id
         AND document.doc_type = 'FINISHED_IN' AND document.status = 1 AND NOT document.is_deleted
        WHERE output.upstream_item_id = plan_item.id AND output.bill_type = 'FINISHED_IN'
          AND NOT output.is_deleted AND NOT fn_finished_in_is_public_output(output.id)
    ) received ON TRUE
    WHERE plan.material_analysis_id = item.analysis_id
      AND plan.material_analysis_item_id = item.id
      AND plan.status = 1 AND NOT plan.is_deleted AND NOT plan.is_canceled
      AND COALESCE(plan_item.unit_rate, 1) > 0
) finished ON TRUE
LEFT JOIN LATERAL (
    -- Same exact pending-allocation authority as MaterialAnalysisService.
    -- MAKE plans are already in submitted_qty/approved_qty; subtracting their
    -- action again would conceal a genuine unarranged remainder.
    SELECT SUM(supply.qty) AS qty FROM (
    SELECT GREATEST(CASE
        WHEN fn_preplan_action_has_future_transfer(action.id)
          OR fn_preplan_action_has_shared_claim_history(action.id)
            THEN fn_preplan_future_allocation_pending_qty(allocation.id)
        WHEN action.operation_type = 'SHARED_FUTURE_CLAIM'
            THEN fn_preplan_shared_allocation_pending_qty(allocation.id)
        ELSE fn_preplan_allocation_admitted_qty(allocation.id)
             - fn_preplan_allocation_effective_exact_qty(allocation.id)
             - COALESCE((
                 SELECT SUM(CASE WHEN output.event_kind = 'FULFILL'
                            THEN output.qty_base ELSE -output.qty_base END)
                 FROM preplan_root_output_events output
                 JOIN preplan_analysis_stock_exact_pegs exact
                   ON exact.stock_reservation_id = output.source_reservation_id
                 WHERE exact.supply_action_allocation_id = allocation.id), 0)
        END, 0) AS qty
    FROM preplan_supply_action_allocations allocation
    JOIN preplan_supply_actions action ON action.id = allocation.action_id
    WHERE allocation.analysis_id = item.analysis_id
      AND allocation.analysis_material_id = COALESCE(item.root_material_id, parent.id)
      AND action.status IN ('OPEN', 'CREATED', 'IN_PROGRESS')
      AND action.external_document_type <> 'PREPLAN_MAKE_TASK'
    UNION ALL
    SELECT fn_preplan_make_public_claim_pending_qty(claim.id)
    FROM preplan_make_public_claims claim
    WHERE claim.target_analysis_id = item.analysis_id
      AND claim.target_material_id = COALESCE(item.root_material_id, parent.id)
    ) supply
) pending ON TRUE
WHERE NOT item.is_deleted AND item.requested_qty > 0;

COMMENT ON VIEW v_production_analysis_workbench_item_progress IS
    'Exact source demand remaining to arrange and fulfill; qualified stock/output, plans and pending supply retain distinct meanings.';

-- Use the same actual fulfillment facts for analysis history and root discovery.
-- Issuing plans, announcing procurement and public stock candidates remain open.
-- This runs inside row triggers, so it calls fn_production_workbench_component_credits
-- directly with the one analysis id instead of joining the all-analyses progress
-- view (whose DISTINCT + LATERAL shape cannot be narrowed to a single analysis).
CREATE OR REPLACE FUNCTION fn_material_analysis_fulfillment_status(p_analysis_id UUID)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    WITH credit AS (
        SELECT c.analysis_item_id,c.fulfillment_credit
        FROM fn_production_workbench_component_credits(p_analysis_id) c
    )
    SELECT CASE
      WHEN analysis.status = 'CANCELLED' THEN 'CANCELLED'
      WHEN NOT EXISTS (
          SELECT 1
          FROM production_material_analysis_items item
          LEFT JOIN credit ON credit.analysis_item_id = item.id
          LEFT JOIN LATERAL (
              SELECT SUM(GREATEST(LEAST(link.submitted_qty,
                     GREATEST(plan_item.qty - COALESCE(batch_action.public_surplus_qty
                         / COALESCE(plan_item.unit_rate, 1), link.public_surplus_qty, 0), 0),
                     COALESCE(received.qty, 0) / COALESCE(plan_item.unit_rate, 1)), 0)) AS qty
              FROM production_plans plan
              JOIN production_plan_items plan_item
                ON plan_item.plan_id = plan.id AND NOT plan_item.is_deleted
              JOIN production_material_analysis_plan_links link
                ON link.plan_id = plan.id AND link.analysis_id = item.analysis_id
                 AND link.analysis_item_id = item.id AND link.allocation_status = 'APPROVED'
              LEFT JOIN preplan_aggregate_batches batch ON batch.plan_id = plan.id AND batch.route = 'MAKE'
              LEFT JOIN preplan_supply_actions batch_action
                ON batch_action.id = batch.action_id AND batch_action.status <> 'CANCELLED'
              LEFT JOIN LATERAL (
                  SELECT SUM(output.base_qty) AS qty
                  FROM stock_document_items output
                  JOIN stock_documents document ON document.id = output.doc_id
                   AND document.doc_type = 'FINISHED_IN' AND document.status = 1 AND NOT document.is_deleted
                  WHERE output.upstream_item_id = plan_item.id AND output.bill_type = 'FINISHED_IN'
                    AND NOT output.is_deleted AND NOT fn_finished_in_is_public_output(output.id)
              ) received ON TRUE
              WHERE plan.material_analysis_id = item.analysis_id
                AND plan.material_analysis_item_id = item.id
                AND plan.status = 1 AND NOT plan.is_deleted AND NOT plan.is_canceled
                AND COALESCE(plan_item.unit_rate, 1) > 0
          ) finished ON TRUE
          WHERE item.analysis_id = analysis.id
            AND NOT item.is_deleted AND item.requested_qty > 0
            AND GREATEST(item.requested_qty - item.root_fulfilled_qty
                     - COALESCE(finished.qty, 0)
                     - CASE WHEN item.source_type = 'MAKE_COMPONENT'
                            THEN COALESCE(credit.fulfillment_credit, 0) ELSE 0 END, 0) > 0)
        AND NOT EXISTS (
            SELECT 1 FROM preplan_supply_actions action
            WHERE action.analysis_id = analysis.id AND action.status IN ('OPEN', 'CREATED', 'IN_PROGRESS'))
        AND NOT EXISTS (
            SELECT 1 FROM preplan_make_public_claims claim
            WHERE claim.target_analysis_id = analysis.id AND fn_preplan_make_public_claim_pending_qty(claim.id) > 0)
        THEN 'COMPLETED'
      WHEN EXISTS (
          SELECT 1 FROM production_material_analysis_items item
          WHERE item.analysis_id = analysis.id AND NOT item.is_deleted
            AND item.submitted_qty + item.approved_qty + item.root_fulfilled_qty > 0)
        THEN 'PARTIALLY_PLANNED'
      ELSE 'ACTIVE' END
    FROM production_material_analyses analysis WHERE analysis.id = p_analysis_id;
$$;

CREATE OR REPLACE VIEW v_production_execution_workbench_roots AS
WITH analysis_roots AS (
    SELECT 'ANALYSIS'::text AS root_type,
           analysis.id AS root_id,
           analysis.maker_id AS owner_employee_id,
           maker.full_name AS owner_employee_name,
           COALESCE(analysis.analysis_no,
                    '物料分析 ' || left(analysis.id::text, 8)) AS root_label,
           analysis.status AS source_status,
           analysis.analyzed_at
    FROM production_material_analyses analysis
    LEFT JOIN employees maker ON maker.id = analysis.maker_id
    WHERE analysis.is_deleted = FALSE AND analysis.status <> 'CANCELLED'
), legacy_roots AS (
    SELECT 'PLAN'::text AS root_type,
           plan.id AS root_id,
           plan.maker_id AS owner_employee_id,
           maker.full_name AS owner_employee_name,
           COALESCE(plan.bill_no,
                    '历史计划 ' || left(plan.id::text, 8)) AS root_label,
           plan.status::text AS source_status,
           plan.created_at AS analyzed_at
    FROM production_plans plan
    LEFT JOIN employees maker ON maker.id = plan.maker_id
    WHERE plan.is_deleted = FALSE AND plan.material_analysis_id IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM subplan_links parent_link
          WHERE parent_link.subplan_id = plan.id
            AND parent_link.is_deleted = FALSE)
), roots AS (
    SELECT * FROM analysis_roots
    UNION ALL
    SELECT * FROM legacy_roots
),
-- 根分析行（顶层产品）：锚点子件行（MAKE_COMPONENT）与
-- 其余带父行都不是顶层；顶层进度只统计这些行的计划段。
root_analysis_items AS (
    SELECT item.analysis_id, item.id
    FROM production_material_analysis_items item
    WHERE item.is_deleted = FALSE
      AND item.parent_analysis_material_id IS NULL
      AND item.source_type <> 'MAKE_COMPONENT'
),
-- 顶层完工进度：只聚合根分析行（PLAN 根全量）的计划/实收入库数量。
-- 子件锚点段与委外前置段的完工不冒充顶层产品进度。
root_progress_rollup AS (
    SELECT task.root_type, task.root_id,
           SUM(task.planned_qty) AS root_planned_qty,
           SUM(LEAST(task.planned_inbound_qty, task.planned_qty))
               AS root_inbound_qty
    FROM v_production_execution_workbench_segments task
    JOIN production_plans plan
      ON plan.id = task.plan_id AND plan.is_deleted = FALSE
    LEFT JOIN root_analysis_items root_item
      ON root_item.analysis_id = plan.material_analysis_id
     AND root_item.id = plan.material_analysis_item_id
    WHERE task.root_type = 'PLAN'
       OR (task.root_type = 'ANALYSIS' AND root_item.id IS NOT NULL)
    GROUP BY task.root_type, task.root_id
),
-- 单趟段聚合：全部计数与工单号预览来自一次段视图扫描（V470 每根各扫一次）。
segment_rollup AS (
    SELECT task.root_type,
           task.root_id,
           COUNT(DISTINCT task.plan_id)::integer AS plan_count,
           COUNT(*)::integer AS segment_count,
           COUNT(*) FILTER (WHERE task.segment_status NOT IN
               ('COMPLETED','CANCELLED','REVERSED'))::integer AS open_segment_count,
           COUNT(*) FILTER (WHERE task.segment_status = 'WAITING')::integer AS waiting_count,
           COUNT(*) FILTER (WHERE task.segment_status = 'READY')::integer AS ready_count,
           COUNT(*) FILTER (WHERE task.segment_status = 'DISPATCHED')::integer AS dispatched_count,
           COUNT(*) FILTER (WHERE task.segment_status = 'IN_PROGRESS')::integer AS in_progress_count,
           COUNT(*) FILTER (WHERE task.segment_status = 'COMPLETED')::integer AS completed_count,
           COUNT(*) FILTER (WHERE task.segment_status NOT IN
               ('COMPLETED','CANCELLED','REVERSED')
               AND task.material_status = 'KIT_READY')::integer AS material_ready_count,
           COUNT(*) FILTER (WHERE task.segment_status NOT IN
               ('COMPLETED','CANCELLED','REVERSED') AND task.warehouse_ready)::integer
               AS warehouse_ready_count,
           COUNT(*) FILTER (WHERE task.segment_status NOT IN
               ('COMPLETED','CANCELLED','REVERSED') AND task.issued)::integer AS issued_count,
           COUNT(*) FILTER (WHERE task.reportable)::integer AS reportable_count,
           COUNT(*) FILTER (WHERE task.fqc_pending_qty > 0)::integer AS fqc_pending_count,
           COUNT(*) FILTER (WHERE task.finished_inbound_pending_qty > 0)::integer
               AS finished_pending_count,
           MIN(task.plan_begin_date) AS earliest_begin_date,
           MAX(task.plan_end_date) AS latest_end_date,
           string_agg(task.segment_code, ' / ' ORDER BY task.segment_code)
               FILTER (WHERE task.code_position <= 3) AS work_order_preview
    FROM (
        SELECT v_segments.*,
               row_number() OVER (
                   PARTITION BY v_segments.root_type, v_segments.root_id
                   ORDER BY v_segments.segment_code) AS code_position
        FROM v_production_execution_workbench_segments v_segments
    ) task
    GROUP BY task.root_type, task.root_id
),
-- 关联订单：段→销售分摊 + 分析来源行，两路合并后按订单去重、按根聚合。
sales_order_rollup AS (
    SELECT source.root_type, source.root_id,
           COUNT(*)::integer AS total,
           string_agg(source.bill_no, ' / ' ORDER BY source.bill_no)
               FILTER (WHERE source.position <= 3) AS preview
    FROM (
        SELECT grouped.root_type, grouped.root_id, grouped.order_id,
               MIN(grouped.bill_no) AS bill_no,
               row_number() OVER (
                   PARTITION BY grouped.root_type, grouped.root_id
                   ORDER BY MIN(grouped.bill_no), grouped.order_id) AS position
        FROM (
            SELECT task.root_type, task.root_id,
                   sales_order.id AS order_id, sales_order.bill_no
            FROM v_production_execution_workbench_segments task
            JOIN execution_segment_sales_allocations allocation
              ON allocation.execution_segment_id = task.segment_id
            JOIN sales_order_items sales_item
              ON sales_item.id = allocation.sales_order_item_id
            JOIN sales_orders sales_order ON sales_order.id = sales_item.order_id
            UNION ALL
            SELECT 'ANALYSIS', analysis_item.analysis_id,
                   sales_order.id, sales_order.bill_no
            FROM production_material_analysis_items analysis_item
            JOIN sales_order_items sales_item
              ON sales_item.id = analysis_item.sales_order_item_id
            JOIN sales_orders sales_order ON sales_order.id = sales_item.order_id
            WHERE analysis_item.is_deleted = FALSE
        ) grouped
        GROUP BY grouped.root_type, grouped.root_id, grouped.order_id
    ) source
    GROUP BY source.root_type, source.root_id
),
-- 生产车间：计数按车间部门去重；预览按车间名去重取前三个（两套口径与 V470 相同）。
workshop_count_rollup AS (
    SELECT task.root_type, task.root_id,
           COUNT(DISTINCT task.workshop_department_id)::integer AS total
    FROM v_production_execution_workbench_segments task
    GROUP BY task.root_type, task.root_id
), workshop_preview_rollup AS (
    SELECT distinct_ws.root_type, distinct_ws.root_id,
           string_agg(distinct_ws.workshop_name, ' / '
                      ORDER BY distinct_ws.workshop_name)
               FILTER (WHERE distinct_ws.position <= 3) AS preview
    FROM (
        SELECT ranked.root_type, ranked.root_id, ranked.workshop_name,
               row_number() OVER (
                   PARTITION BY ranked.root_type, ranked.root_id
                   ORDER BY ranked.workshop_name) AS position
        FROM (
            SELECT DISTINCT task.root_type, task.root_id, task.workshop_name
            FROM v_production_execution_workbench_segments task
            WHERE task.workshop_name IS NOT NULL
        ) ranked
    ) distinct_ws
    GROUP BY distinct_ws.root_type, distinct_ws.root_id
),
-- 产品颜色：两路原始行合并去重取前三个（V490 前保持与 V470 完全同源）。
color_rollup AS (
    SELECT distinct_colors.root_type, distinct_colors.root_id,
           string_agg(distinct_colors.color_name, ' / '
                      ORDER BY distinct_colors.color_name)
               FILTER (WHERE distinct_colors.position <= 3) AS preview
    FROM (
        SELECT ranked.root_type, ranked.root_id, ranked.color_name,
               row_number() OVER (
                   PARTITION BY ranked.root_type, ranked.root_id
                   ORDER BY ranked.color_name) AS position
        FROM (
            SELECT DISTINCT task.root_type, task.root_id, task.product_color_name AS color_name
            FROM v_production_execution_workbench_segments task
            WHERE task.product_color_name IS NOT NULL
            UNION
            SELECT 'ANALYSIS', analysis_item.analysis_id, color.name
            FROM production_material_analysis_items analysis_item
            JOIN colors color ON color.id = analysis_item.color_id
            WHERE analysis_item.is_deleted = FALSE AND color.name IS NOT NULL
        ) ranked
    ) distinct_colors
    GROUP BY distinct_colors.root_type, distinct_colors.root_id
),
-- 产品：分析来源行 + 段产品两路合并，按货品去重（编码/名称取 MIN，与 V470 相同）。
product_rollup AS (
    SELECT grouped.root_type, grouped.root_id,
           COUNT(*)::integer AS total,
           string_agg(grouped.code, ' / ' ORDER BY grouped.code)
               FILTER (WHERE grouped.position <= 3) AS code_preview,
           string_agg(grouped.name, ' / ' ORDER BY grouped.name)
               FILTER (WHERE grouped.position <= 3) AS name_preview
    FROM (
        SELECT inner_grouped.root_type, inner_grouped.root_id,
               inner_grouped.goods_id, MIN(inner_grouped.code) AS code,
               MIN(inner_grouped.name) AS name,
               row_number() OVER (
                   PARTITION BY inner_grouped.root_type, inner_grouped.root_id
                   ORDER BY MIN(inner_grouped.code), inner_grouped.goods_id) AS position
        FROM (
            SELECT 'ANALYSIS' AS root_type, analysis_item.analysis_id AS root_id,
                   analysis_item.goods_id, goods.code, goods.name
            FROM production_material_analysis_items analysis_item
            JOIN goods ON goods.id = analysis_item.goods_id
            WHERE analysis_item.is_deleted = FALSE
            UNION ALL
            SELECT task.root_type, task.root_id, task.product_goods_id,
                   task.product_code, task.product_name
            FROM v_production_execution_workbench_segments task
        ) inner_grouped
        GROUP BY inner_grouped.root_type, inner_grouped.root_id, inner_grouped.goods_id
    ) grouped
    GROUP BY grouped.root_type, grouped.root_id
),
-- 数量摘要：段按单位聚合；无段的分析根回退按分析行需求聚合（反连已算好的
-- segment_rollup，不再逐行探测段视图）。
quantity_rollup AS (
    SELECT ranked.root_type, ranked.root_id,
           COUNT(*)::integer AS total_units,
           string_agg(
               COALESCE(ranked.unit_name,'单位未维护') || ': 计划 ' || ranked.planned_qty::text
               || ' / 报工 ' || ranked.reported_qty::text
               || ' / FQC待检 ' || ranked.fqc_pending_qty::text
               || ' / 通过 ' || ranked.fqc_passed_qty::text
               || ' / 失败 ' || ranked.fqc_failed_qty::text
               || ' / 待点收 ' || ranked.inbound_pending_qty::text
               || ' / 实收 ' || ranked.inbound_qty::text,
               ' / ' ORDER BY ranked.unit_name) FILTER (WHERE ranked.position <= 3)
               AS preview
    FROM (
        SELECT unit_totals.root_type, unit_totals.root_id,
               unit_totals.unit_name, unit_totals.planned_qty,
               unit_totals.reported_qty, unit_totals.fqc_pending_qty,
               unit_totals.fqc_passed_qty, unit_totals.fqc_failed_qty,
               unit_totals.inbound_pending_qty, unit_totals.inbound_qty,
               row_number() OVER (
                   PARTITION BY unit_totals.root_type, unit_totals.root_id
                   ORDER BY unit_totals.unit_name) AS position
        FROM (
            SELECT task.root_type, task.root_id,
                   task.product_unit_name AS unit_name,
                   SUM(task.planned_qty) AS planned_qty,
                   SUM(task.reported_qty) AS reported_qty,
                   SUM(task.fqc_pending_qty) AS fqc_pending_qty,
                   SUM(task.fqc_passed_qty) AS fqc_passed_qty,
                   SUM(task.fqc_failed_qty) AS fqc_failed_qty,
                   SUM(task.finished_inbound_pending_qty) AS inbound_pending_qty,
                   SUM(task.inbound_qty) AS inbound_qty
            FROM v_production_execution_workbench_segments task
            GROUP BY task.root_type, task.root_id, task.product_unit_name
            UNION ALL
            SELECT 'ANALYSIS', item.analysis_id, unit.name,
                   SUM(item.requested_qty), 0, 0, 0, 0, 0, 0
            FROM production_material_analysis_items item
            JOIN units unit ON unit.id = item.unit_id
            WHERE item.is_deleted = FALSE
              AND NOT EXISTS (
                  SELECT 1 FROM segment_rollup rolled
                  WHERE rolled.root_type = 'ANALYSIS'
                    AND rolled.root_id = item.analysis_id)
            GROUP BY item.analysis_id, unit.name
        ) unit_totals
    ) ranked
    GROUP BY ranked.root_type, ranked.root_id
)
SELECT root.root_type, root.root_id, root.owner_employee_id, root.root_label,
       CASE
           WHEN COALESCE(demand.remaining_qty, 0) > 0
                AND (COALESCE(segment.segment_count, 0) > 0
                     OR COALESCE(action.open_count, 0) > 0)
             THEN 'PARTIALLY_SCHEDULED'
           WHEN COALESCE(segment.segment_count, 0) = 0
                AND COALESCE(plan.open_count, 0) > 0 THEN 'PLAN_PENDING'
           WHEN COALESCE(segment.segment_count, 0) = 0
                AND COALESCE(action.open_count, 0) > 0 THEN 'PREPARING'
           WHEN COALESCE(segment.segment_count, 0) = 0 THEN 'ANALYZING'
           WHEN COALESCE(segment.open_segment_count, 0) = 0
                AND COALESCE(action.open_count, 0) > 0 THEN 'PREPARING'
           WHEN COALESCE(segment.open_segment_count, 0) = 0
                AND COALESCE(plan.open_count, 0) > 0 THEN 'PLAN_PENDING'
           WHEN COALESCE(segment.in_progress_count, 0) > 0 THEN 'IN_PROGRESS'
           WHEN COALESCE(segment.issued_count, 0)
               = COALESCE(segment.open_segment_count, 0)
               AND COALESCE(segment.open_segment_count, 0) > 0 THEN 'PREPARED'
           WHEN COALESCE(segment.material_ready_count, 0)
               < COALESCE(segment.open_segment_count, 0) THEN 'KIT_SHORT'
           ELSE 'KIT_READY_PREPARING'
       END AS status,
       sales.preview AS sales_order_preview,
       COALESCE(sales.total, 0)::integer AS sales_order_count,
       COALESCE(sales.total, 0) > 3 AS sales_order_has_more,
       segment.work_order_preview AS work_order_preview,
       COALESCE(segment.segment_count, 0)::integer AS work_order_count,
       COALESCE(segment.segment_count, 0) > 3 AS work_order_has_more,
       workshop_preview.preview AS workshop_preview,
       COALESCE(workshop_count.total, 0)::integer AS workshop_count,
       COALESCE(workshop_count.total, 0) > 3 AS workshop_has_more,
       product.code_preview AS product_code_preview,
       product.name_preview AS product_name_preview,
       color.preview AS product_color_preview,
       COALESCE(product.total, 0)::integer AS product_count,
       COALESCE(product.total, 0) > 3 AS product_has_more,
       quantity.preview AS quantity_summary,
       COALESCE(quantity.total_units, 0) > 1 AS mixed_units,
       COALESCE(quantity.total_units, 0)::integer AS execution_unit_count,
       COALESCE(quantity.total_units, 0) > 3 AS execution_unit_has_more,
       GREATEST(COALESCE(plan.plan_count,0),COALESCE(segment.plan_count,0))::integer AS plan_count,
       COALESCE(segment.segment_count, 0)::integer AS segment_count,
       COALESCE(segment.waiting_count, 0)::integer AS waiting_count,
       COALESCE(segment.ready_count, 0)::integer AS ready_count,
       COALESCE(segment.dispatched_count, 0)::integer AS dispatched_count,
       COALESCE(segment.in_progress_count, 0)::integer AS in_progress_count,
       COALESCE(segment.completed_count, 0)::integer AS completed_count,
       COALESCE(segment.material_ready_count, 0)::integer AS material_ready_count,
       COALESCE(segment.warehouse_ready_count, 0)::integer AS warehouse_ready_count,
       COALESCE(segment.issued_count, 0)::integer AS issued_count,
       COALESCE(segment.reportable_count, 0)::integer AS reportable_count,
       COALESCE(segment.fqc_pending_count, 0)::integer AS fqc_pending_count,
       COALESCE(segment.finished_pending_count, 0)::integer
           AS finished_inbound_pending_count,
       COALESCE(segment.earliest_begin_date, plan.earliest_begin_date)
           AS earliest_begin_date,
       COALESCE(segment.latest_end_date, plan.latest_end_date)
           AS latest_end_date,
       root.source_status,
       COALESCE(demand.remaining_qty, 0)::numeric AS remaining_demand_qty,
       COALESCE(action.open_count, 0)::integer AS open_action_count,
       COALESCE(plan.open_count, 0)::integer AS open_plan_count,
       COALESCE(segment.open_segment_count, 0)::integer AS open_segment_count,
       root.owner_employee_name,
       root.analyzed_at,
       COALESCE(progress.root_planned_qty, 0)::numeric AS root_planned_qty,
       COALESCE(progress.root_inbound_qty, 0)::numeric AS root_inbound_qty,
       CASE WHEN COALESCE(progress.root_planned_qty, 0) > 0
            THEN LEAST(COALESCE(progress.root_inbound_qty, 0)
                       / progress.root_planned_qty, 1)
            ELSE NULL END AS root_progress_ratio
FROM roots root
LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(item.remaining_schedule_qty),0)
               AS remaining_qty
    FROM v_production_analysis_workbench_item_progress item
    WHERE root.root_type = 'ANALYSIS' AND item.analysis_id = root.root_id
) demand ON TRUE
LEFT JOIN LATERAL (
    SELECT (COUNT(*) FILTER (
               WHERE action.status IN ('OPEN','CREATED','IN_PROGRESS'))
            + (SELECT COUNT(*) FROM preplan_make_public_claims claim
               WHERE root.root_type = 'ANALYSIS' AND claim.target_analysis_id = root.root_id
                 AND fn_preplan_make_public_claim_pending_qty(claim.id) > 0))::integer
               AS open_count
    FROM preplan_supply_actions action
    WHERE root.root_type = 'ANALYSIS' AND action.analysis_id = root.root_id
) action ON TRUE
LEFT JOIN LATERAL (
    SELECT COUNT(*)::integer AS plan_count,
           COUNT(*) FILTER (
               WHERE plan.status = 0 OR (plan.status = 1
                 AND plan.is_closed = FALSE AND plan.is_stopped = FALSE
                 AND plan.is_canceled = FALSE
                 AND EXISTS (
                     SELECT 1 FROM production_plan_items plan_item
                     WHERE plan_item.plan_id = plan.id AND NOT plan_item.is_deleted
                       AND plan_item.qty > COALESCE(plan_item.iqty, 0))))::integer AS open_count,
           MIN(plan.bill_date) AS earliest_begin_date,
           MAX(plan.delivery_date) AS latest_end_date
    FROM production_plans plan
    WHERE (root.root_type = 'ANALYSIS'
           AND plan.material_analysis_id = root.root_id
           AND plan.is_deleted = FALSE)
       OR (root.root_type = 'PLAN' AND plan.id = root.root_id
           AND plan.is_deleted = FALSE)
) plan ON TRUE
LEFT JOIN segment_rollup segment
  ON segment.root_type = root.root_type AND segment.root_id = root.root_id
LEFT JOIN sales_order_rollup sales
  ON sales.root_type = root.root_type AND sales.root_id = root.root_id
LEFT JOIN workshop_count_rollup workshop_count
  ON workshop_count.root_type = root.root_type
 AND workshop_count.root_id = root.root_id
LEFT JOIN workshop_preview_rollup workshop_preview
  ON workshop_preview.root_type = root.root_type
 AND workshop_preview.root_id = root.root_id
LEFT JOIN product_rollup product
  ON product.root_type = root.root_type AND product.root_id = root.root_id
LEFT JOIN color_rollup color
  ON color.root_type = root.root_type AND color.root_id = root.root_id
LEFT JOIN quantity_rollup quantity
  ON quantity.root_type = root.root_type AND quantity.root_id = root.root_id
LEFT JOIN root_progress_rollup progress
  ON progress.root_type = root.root_type AND progress.root_id = root.root_id
WHERE (root.root_type='ANALYSIS' AND
       (COALESCE(demand.remaining_qty,0)>0 OR COALESCE(action.open_count,0)>0
        OR COALESCE(plan.open_count,0)>0 OR COALESCE(segment.open_segment_count,0)>0))
   OR (root.root_type='PLAN' AND
       (COALESCE(plan.open_count,0)>0 OR COALESCE(segment.open_segment_count,0)>0));

COMMENT ON VIEW v_production_execution_workbench_roots IS
    'One bounded row per outer analysis; legacy plans use the outermost plan UUID. V485: single-pass rollups (V470 scanned the segment view once per root per fact). V487: +maker/analyzed_at and top-level root-only completion progress; zero-material flag on the segment view. V719: analysis root_label prefers the WL analysis_no, falling back to the id-8 hex label only when absent.';
