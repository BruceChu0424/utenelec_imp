-- Freeze the accepted fraction of the existing material loss allowance for new drafts.
-- Legacy drafts and all previously approved material plan snapshots retain their basis.
ALTER TABLE subcontract_order_items
    ADD COLUMN material_supply_loss_factor NUMERIC(9,8),
    ADD COLUMN material_supply_funded_loss_factor NUMERIC(9,8),
    ADD CONSTRAINT subcontract_order_material_supply_loss_factor_chk
        CHECK (material_supply_loss_factor BETWEEN 0 AND 1
            AND (material_supply_funded_loss_factor IS NULL OR
                (material_supply_loss_factor IS NOT NULL AND material_supply_loss_factor = 1
                 AND material_supply_funded_loss_factor >= 0 AND material_supply_funded_loss_factor < 1)));
COMMENT ON COLUMN subcontract_order_items.material_supply_funded_loss_factor IS
    'Only set when continuing with the full material budget despite short stock. The unfunded balance does not crowd out the other orders already using the kit pools.';

CREATE FUNCTION fn_subcontract_effective_supply_loss_pct(p_pct NUMERIC, p_factor NUMERIC)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT ROUND(COALESCE(p_pct, 0) * COALESCE(p_factor, 1), 24)
$$;


CREATE FUNCTION fn_subcontract_order_item_component_need_at_factor(
    p_order_item UUID, p_goods UUID, p_color UUID, p_factor NUMERIC)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE((
        SELECT CASE
            WHEN header.status = 1 THEN COALESCE((
                SELECT SUM(GREATEST(LEAST(
                                    fn_subcontract_draw_needed_qty(line.order_item_id, line.planned_qty, line.bom_unit_qty),
                                    CASE WHEN p_factor IS NULL AND item.material_supply_funded_loss_factor IS NOT NULL
                                         THEN fn_subcontract_draw_f(item.qty, fn_subcontract_supply_unit_qty(
                                             line.base_bom_unit_qty, fn_subcontract_effective_supply_loss_pct(
                                                 line.material_loss_pct, item.material_supply_funded_loss_factor)))
                                         ELSE line.planned_qty END)
                                    - line.issued_qty
                                    - COALESCE((SELECT SUM(draft_item.qty)
                                                FROM subcontract_material_issue_items draft_item
                                                JOIN subcontract_material_issues draft ON draft.id = draft_item.issue_id
                                                 AND draft.status = 0 AND NOT draft.is_deleted
                                                WHERE draft_item.plan_item_id = line.id AND NOT draft_item.is_deleted), 0), 0))
                FROM subcontract_material_plan_items line
                JOIN subcontract_material_plans plan ON plan.id = line.plan_id
                 AND plan.status = 'OPEN' AND NOT plan.is_deleted
                WHERE line.order_item_id = item.id AND NOT line.is_deleted AND line.draw_closed_at IS NULL
                  AND line.goods_id = p_goods AND line.color_id IS NOT DISTINCT FROM p_color), 0)
            ELSE COALESCE((
                SELECT SUM(fn_subcontract_draw_f(item.qty, fn_subcontract_supply_unit_qty(
                    ROUND(COALESCE(item.unit_rate, 1) * edge.edge_qty, 6),
                    fn_subcontract_effective_supply_loss_pct(item.allowed_loss_pct,
                        COALESCE(p_factor, item.material_supply_funded_loss_factor,
                                 item.material_supply_loss_factor, 0)))))
                FROM fn_subcontract_draw_edges(item.goods_id) edge
                WHERE edge.component_goods_id = p_goods AND edge.color_id IS NOT DISTINCT FROM p_color), 0)
        END
        FROM subcontract_order_items item
        JOIN subcontract_orders header ON header.id = item.order_id
        WHERE item.id = p_order_item AND NOT item.is_deleted AND COALESCE(item.qty, 0) > 0
          AND NOT header.is_deleted AND header.status IN (0, 1) AND NOT COALESCE(header.is_closed, FALSE)
    ), 0)
$function$;

CREATE OR REPLACE FUNCTION fn_subcontract_order_item_component_need(p_order_item UUID, p_goods UUID, p_color UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT fn_subcontract_order_item_component_need_at_factor(p_order_item, p_goods, p_color, NULL)
$$;


CREATE FUNCTION fn_subcontract_component_pool_demands_for_orders(
    p_dimensions JSONB, p_exclude_orders UUID[], p_only_orders UUID[], p_factor NUMERIC)
RETURNS TABLE(goods_id UUID, color_id UUID, application_item_id UUID, demand_qty NUMERIC)
LANGUAGE sql STABLE
AS $function$
    WITH dimensions AS MATERIALIZED (
        SELECT DISTINCT request.goods_id, request.color_id
        FROM jsonb_to_recordset(COALESCE(p_dimensions, '[]'::jsonb))
             AS request(goods_id UUID, color_id UUID)
        WHERE request.goods_id IS NOT NULL
    ), needs AS MATERIALIZED (
        -- The costly leaf is evaluated exactly once per relevant order/dimension.
        -- Neither the positive filter nor source/public projections may inline it.
        SELECT dimension.goods_id, dimension.color_id, item.id AS order_item_id, item.qty,
               fn_subcontract_order_item_component_need_at_factor(item.id, dimension.goods_id, dimension.color_id, p_factor) AS need
        FROM dimensions dimension
        JOIN subcontract_order_items item ON NOT item.is_deleted AND COALESCE(item.qty, 0) > 0
        JOIN subcontract_orders header ON header.id = item.order_id
         AND NOT header.is_deleted AND header.status IN (0, 1) AND NOT COALESCE(header.is_closed, FALSE)
        WHERE (p_exclude_orders IS NULL OR header.id <> ALL(p_exclude_orders))
          AND (p_only_orders IS NULL OR header.id = ANY(p_only_orders))
          AND (EXISTS (SELECT 1 FROM subcontract_material_plan_items line
                       WHERE line.order_item_id = item.id AND NOT line.is_deleted
                         AND line.goods_id = dimension.goods_id
                         AND line.color_id IS NOT DISTINCT FROM dimension.color_id)
               OR EXISTS (SELECT 1 FROM goods_bom_items edge
                          WHERE edge.goods_id = item.goods_id AND edge.component_goods_id = dimension.goods_id
                            AND NOT edge.is_deleted))
    ), positive AS MATERIALIZED (
        SELECT needs.* FROM needs WHERE needs.need > 0
    ), sourced AS MATERIALIZED (
        SELECT positive.goods_id, positive.color_id, positive.order_item_id,
               source.application_item_id, positive.need, positive.qty, source.alloc_qty,
               SUM(source.alloc_qty) OVER (
                   PARTITION BY positive.goods_id, positive.color_id, positive.order_item_id
                   ORDER BY source.line_no, source.id) AS cumulative_alloc
        FROM positive
        JOIN subcontract_order_item_sources source ON source.order_item_id = positive.order_item_id
         AND source.alloc_qty > 0
    ), allocated AS (
        SELECT sourced.goods_id, sourced.color_id, sourced.order_item_id, SUM(sourced.alloc_qty) AS total
        FROM sourced GROUP BY sourced.goods_id, sourced.color_id, sourced.order_item_id
    ), shares AS (
        SELECT sourced.goods_id, sourced.color_id, sourced.application_item_id,
               ROUND(sourced.need * LEAST(sourced.cumulative_alloc, sourced.qty) / sourced.qty, 4)
               - ROUND(sourced.need * LEAST(sourced.cumulative_alloc - sourced.alloc_qty, sourced.qty) / sourced.qty, 4) AS share
        FROM sourced
        UNION ALL
        SELECT positive.goods_id, positive.color_id, NULL::uuid,
               positive.need - ROUND(positive.need * LEAST(COALESCE(allocated.total, 0), positive.qty) / positive.qty, 4)
        FROM positive LEFT JOIN allocated ON allocated.goods_id = positive.goods_id
         AND allocated.color_id IS NOT DISTINCT FROM positive.color_id
         AND allocated.order_item_id = positive.order_item_id
    )
    SELECT shares.goods_id, shares.color_id, shares.application_item_id, SUM(shares.share)
    FROM shares GROUP BY shares.goods_id, shares.color_id, shares.application_item_id
    HAVING SUM(shares.share) > 0
$function$;

CREATE OR REPLACE FUNCTION fn_subcontract_component_pool_demands_batch(
    p_dimensions JSONB, p_exclude_order UUID, p_only_order UUID DEFAULT NULL)
RETURNS TABLE(goods_id UUID, color_id UUID, application_item_id UUID, demand_qty NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_subcontract_component_pool_demands_for_orders(
        p_dimensions, CASE WHEN p_exclude_order IS NOT NULL THEN ARRAY[p_exclude_order] END,
        CASE WHEN p_only_order IS NOT NULL THEN ARRAY[p_only_order] END, NULL)
$$;


CREATE FUNCTION fn_subcontract_kit_pool_facts_excluding(p_requests JSONB, p_exclude_orders UUID[])
RETURNS TABLE(goods_id UUID, color_id UUID, application_item_id UUID, demand_qty NUMERIC,
              exact_qty NUMERIC, exact_free_qty NUMERIC, public_qty NUMERIC,
              public_claimed_qty NUMERIC, public_free_qty NUMERIC)
LANGUAGE sql STABLE
AS $function$
    WITH requested AS MATERIALIZED (
        SELECT DISTINCT request.goods_id, request.color_id, request.application_item_id
        FROM jsonb_to_recordset(COALESCE(p_requests, '[]'::jsonb))
             AS request(goods_id UUID, color_id UUID, application_item_id UUID)
        WHERE request.goods_id IS NOT NULL
    ), dimensions AS MATERIALIZED (
        SELECT DISTINCT requested.goods_id, requested.color_id FROM requested
    ), demands AS MATERIALIZED (
        SELECT demand.* FROM fn_subcontract_component_pool_demands_for_orders(
            (SELECT COALESCE(jsonb_agg(to_jsonb(dimension)), '[]'::jsonb) FROM dimensions dimension),
            p_exclude_orders, NULL, NULL) demand
    ), pool_keys AS (
        SELECT requested.goods_id, requested.color_id, requested.application_item_id FROM requested
        UNION SELECT demands.goods_id, demands.color_id, demands.application_item_id FROM demands
        UNION SELECT dimensions.goods_id, dimensions.color_id, NULL::uuid FROM dimensions
    ), pools AS MATERIALIZED (
        SELECT key.goods_id, key.color_id, key.application_item_id, COALESCE(demand.demand_qty, 0) AS demand_qty,
               CASE WHEN key.application_item_id IS NULL THEN 0
                    ELSE fn_subcontract_application_exact_qty(key.application_item_id, key.goods_id, key.color_id) END AS exact_qty
        FROM pool_keys key LEFT JOIN demands demand ON demand.goods_id = key.goods_id
         AND demand.color_id IS NOT DISTINCT FROM key.color_id
         AND demand.application_item_id IS NOT DISTINCT FROM key.application_item_id
    ), claimed AS (
        SELECT pools.goods_id, pools.color_id,
               SUM(CASE WHEN pools.application_item_id IS NULL THEN pools.demand_qty
                        ELSE GREATEST(pools.demand_qty - pools.exact_qty, 0) END) AS qty
        FROM pools GROUP BY pools.goods_id, pools.color_id
    ), public_side AS MATERIALIZED (
        SELECT dimension.goods_id, dimension.color_id,
               fn_subcontract_component_public_qty(dimension.goods_id, dimension.color_id) AS qty
        FROM dimensions dimension
    )
    SELECT pools.goods_id, pools.color_id, pools.application_item_id, pools.demand_qty,
           pools.exact_qty, GREATEST(pools.exact_qty - pools.demand_qty, 0),
           public_side.qty, claimed.qty, GREATEST(public_side.qty - claimed.qty, 0)
    FROM pools JOIN public_side ON public_side.goods_id = pools.goods_id
     AND public_side.color_id IS NOT DISTINCT FROM pools.color_id
    JOIN claimed ON claimed.goods_id = pools.goods_id AND claimed.color_id IS NOT DISTINCT FROM pools.color_id
$function$;

CREATE OR REPLACE FUNCTION fn_subcontract_kit_pool_facts(p_requests JSONB, p_exclude_order UUID)
RETURNS TABLE(goods_id UUID, color_id UUID, application_item_id UUID, demand_qty NUMERIC,
              exact_qty NUMERIC, exact_free_qty NUMERIC, public_qty NUMERIC,
              public_claimed_qty NUMERIC, public_free_qty NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_subcontract_kit_pool_facts_excluding(
        p_requests, CASE WHEN p_exclude_order IS NOT NULL THEN ARRAY[p_exclude_order] END)
$$;


CREATE OR REPLACE FUNCTION fn_subcontract_order_kit_shortages(p_order UUID)
RETURNS TABLE(goods_id UUID, color_id UUID, need_qty NUMERIC, exact_free_qty NUMERIC,
              public_need_qty NUMERIC, public_free_qty NUMERIC)
LANGUAGE sql STABLE
AS $function$
    WITH items AS MATERIALIZED (
        SELECT item.id, item.goods_id FROM subcontract_order_items item
        WHERE item.order_id = p_order AND NOT item.is_deleted AND COALESCE(item.qty, 0) > 0
    ), dimensions AS MATERIALIZED (
        SELECT DISTINCT edge.component_goods_id AS goods_id, edge.color_id
        FROM items CROSS JOIN LATERAL fn_subcontract_draw_edges(items.goods_id) edge
        UNION SELECT line.goods_id, line.color_id FROM items
        JOIN subcontract_material_plan_items line ON line.order_item_id = items.id AND NOT line.is_deleted
    ), own_pools AS MATERIALIZED (
        SELECT demand.* FROM fn_subcontract_component_pool_demands_for_orders(
            (SELECT COALESCE(jsonb_agg(to_jsonb(dimension)), '[]'::jsonb) FROM dimensions dimension), NULL, ARRAY[p_order], 0) demand
    ), pools AS MATERIALIZED (
        SELECT pool.* FROM fn_subcontract_kit_pool_facts(
            (SELECT COALESCE(jsonb_agg(jsonb_build_object('goods_id', own.goods_id, 'color_id', own.color_id,
                'application_item_id', own.application_item_id)), '[]'::jsonb) FROM own_pools own), p_order) pool
    ), totals AS (
        SELECT own.goods_id, own.color_id, SUM(own.demand_qty) AS need_qty,
               SUM(LEAST(own.demand_qty, CASE WHEN own.application_item_id IS NULL THEN 0 ELSE pool.exact_free_qty END)) AS exact_free_qty,
               SUM(GREATEST(own.demand_qty - CASE WHEN own.application_item_id IS NULL THEN 0 ELSE pool.exact_free_qty END, 0)) AS public_need_qty,
               MAX(pool.public_free_qty) AS public_free_qty
        FROM own_pools own JOIN pools pool ON pool.goods_id = own.goods_id
         AND pool.color_id IS NOT DISTINCT FROM own.color_id
         AND pool.application_item_id IS NOT DISTINCT FROM own.application_item_id
        GROUP BY own.goods_id, own.color_id
    )
    SELECT totals.* FROM totals WHERE totals.public_need_qty > totals.public_free_qty
    ORDER BY totals.goods_id, totals.color_id NULLS FIRST
$function$;

-- The caller holds the shared kit dimension locks. Read the available stock pools
-- once for the entire staged batch; no order in that batch counts as a competing draft.
CREATE FUNCTION fn_subcontract_order_budget_pool_snapshot(p_orders UUID[])
RETURNS JSONB LANGUAGE sql STABLE AS $$
    WITH dimensions AS (
        SELECT DISTINCT edge.component_goods_id AS goods_id, edge.color_id
        FROM subcontract_order_items item
        CROSS JOIN LATERAL fn_subcontract_draw_edges(item.goods_id) edge
        WHERE item.order_id = ANY(p_orders) AND NOT item.is_deleted
    ), own_pools AS (
        SELECT own.goods_id, own.color_id, own.application_item_id
        FROM fn_subcontract_component_pool_demands_for_orders(
            (SELECT jsonb_agg(to_jsonb(dimension)) FROM dimensions dimension), NULL, p_orders, 1) own
    )
    SELECT COALESCE(jsonb_agg(to_jsonb(pool) ORDER BY pool.goods_id, pool.color_id, pool.application_item_id), '[]'::jsonb)
    FROM fn_subcontract_kit_pool_facts_excluding(
        (SELECT jsonb_agg(to_jsonb(own)) FROM own_pools own), p_orders) pool
$$;

CREATE FUNCTION fn_subcontract_order_budget_facts(p_orders UUID[], p_factor NUMERIC, p_pools JSONB)
RETURNS TABLE(goods_id UUID, color_id UUID, need_qty NUMERIC, available_qty NUMERIC, short_qty NUMERIC)
LANGUAGE sql STABLE AS $$
    WITH pools AS MATERIALIZED (
        SELECT * FROM jsonb_to_recordset(p_pools) AS pool(
            goods_id UUID, color_id UUID, application_item_id UUID, exact_free_qty NUMERIC, public_free_qty NUMERIC)
    ), dimensions AS (
        SELECT DISTINCT pool.goods_id, pool.color_id FROM pools pool
    ), own_pools AS (
        SELECT * FROM fn_subcontract_component_pool_demands_for_orders(
            (SELECT jsonb_agg(to_jsonb(dimension)) FROM dimensions dimension), NULL, p_orders, p_factor)
    ), totals AS (
        SELECT own.goods_id, own.color_id, SUM(own.demand_qty) AS need_qty,
               SUM(LEAST(own.demand_qty, pool.exact_free_qty)) AS exact_used,
               SUM(GREATEST(own.demand_qty - pool.exact_free_qty, 0)) AS public_need,
               MAX(pool.public_free_qty) AS public_free
        FROM own_pools own JOIN pools pool ON pool.goods_id = own.goods_id
         AND pool.color_id IS NOT DISTINCT FROM own.color_id
         AND pool.application_item_id IS NOT DISTINCT FROM own.application_item_id
        GROUP BY own.goods_id, own.color_id
    )
    SELECT totals.goods_id, totals.color_id, totals.need_qty, totals.exact_used + totals.public_free,
           GREATEST(totals.public_need - totals.public_free, 0)
    FROM totals
$$;

-- Solve on the stored factor grid. Every candidate uses the exact BOM and source
-- rounding of the committed budget. The base gate has already validated factor 0.
CREATE FUNCTION fn_subcontract_order_budget_cap_factor(p_orders UUID[], p_pools JSONB)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE
    low INTEGER := 0;
    high INTEGER := 100000000;
    middle INTEGER;
BEGIN
    WHILE high - low > 1 LOOP
        middle := (low + high) / 2;
        IF EXISTS (SELECT 1 FROM fn_subcontract_order_budget_facts(p_orders, middle * 0.00000001, p_pools)
                   WHERE short_qty > 0) THEN
            high := middle;
        ELSE
            low := middle;
        END IF;
    END LOOP;
    RETURN low * 0.00000001;
END
$$;


CREATE OR REPLACE FUNCTION fn_guard_subcontract_target_quantity_basis_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.base_bom_unit_qty IS NULL THEN
        NEW.base_bom_unit_qty := NEW.bom_unit_qty;
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM subcontract_order_items order_item
        CROSS JOIN LATERAL fn_subcontract_draw_edges(order_item.goods_id) edge
        JOIN goods component ON component.id = edge.component_goods_id
        WHERE order_item.id = NEW.order_item_id AND NOT order_item.is_deleted
          AND NEW.parent_goods_id = order_item.goods_id
          AND NEW.parent_color_id IS NOT DISTINCT FROM order_item.color_id
          AND NEW.goods_id = edge.component_goods_id
          AND NEW.color_id IS NOT DISTINCT FROM edge.color_id
          AND NEW.unit_id IS NOT DISTINCT FROM component.unit_id
          AND NEW.unit_rate = 1
          AND NEW.base_bom_unit_qty = ROUND(COALESCE(order_item.unit_rate, 1) * edge.edge_qty, 6)
          AND NEW.material_loss_pct = fn_subcontract_effective_supply_loss_pct(
              order_item.allowed_loss_pct, order_item.material_supply_loss_factor)
          AND NEW.bom_unit_qty = fn_subcontract_supply_unit_qty(NEW.base_bom_unit_qty, NEW.material_loss_pct)
          AND NEW.planned_qty = fn_subcontract_draw_f(order_item.qty, NEW.bom_unit_qty)
          AND NEW.issued_qty = 0
          AND NEW.draw_closed_at IS NULL
    ) THEN
        RAISE EXCEPTION 'subcontract draw plan must freeze the direct BOM edge and normal material loss allowance'
            USING ERRCODE = '23514', CONSTRAINT = 'subcontract_draw_plan_basis_guard';
    END IF;
    RETURN NEW;
END;
$$;
