-- V868: one material-pool projection per requested dimension, shared by every
-- kit reader and the existing scalar entry points. V854 open-quantity authority
-- and the existing physical demand/entitlement leaves remain unchanged.
-- No stored inventory, source, financial approval, or notification state changes.

CREATE FUNCTION fn_subcontract_component_pool_demands_batch(
    p_dimensions JSONB, p_exclude_order UUID, p_only_order UUID DEFAULT NULL)
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
               fn_subcontract_order_item_component_need(item.id, dimension.goods_id, dimension.color_id) AS need
        FROM dimensions dimension
        JOIN subcontract_order_items item ON NOT item.is_deleted AND COALESCE(item.qty, 0) > 0
        JOIN subcontract_orders header ON header.id = item.order_id
         AND NOT header.is_deleted AND header.status IN (0, 1) AND NOT COALESCE(header.is_closed, FALSE)
        WHERE header.id IS DISTINCT FROM p_exclude_order
          AND (p_only_order IS NULL OR header.id = p_only_order)
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

CREATE FUNCTION fn_subcontract_kit_pool_facts(p_requests JSONB, p_exclude_order UUID)
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
        SELECT demand.* FROM fn_subcontract_component_pool_demands_batch(
            (SELECT COALESCE(jsonb_agg(to_jsonb(dimension)), '[]'::jsonb) FROM dimensions dimension),
            p_exclude_order, NULL) demand
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

CREATE FUNCTION fn_subcontract_application_kit_facts_batch(p_application_items UUID[], p_exclude_order UUID)
RETURNS TABLE(application_item_id UUID, edge_id UUID, component_goods_id UUID, color_id UUID,
              sort_order INTEGER, bom_unit_qty NUMERIC, exact_qty NUMERIC, exact_claimed_qty NUMERIC,
              exact_free_qty NUMERIC, public_qty NUMERIC, public_claimed_qty NUMERIC,
              public_free_qty NUMERIC, free_qty NUMERIC, kit_qty NUMERIC)
LANGUAGE sql STABLE
AS $function$
    WITH edges AS MATERIALIZED (
        SELECT application.id AS application_item_id, edge.edge_id, edge.component_goods_id,
               edge.color_id, edge.sort_order, ROUND(COALESCE(application.unit_rate, 1) * edge.edge_qty, 6) AS bom_unit_qty
        FROM subcontract_application_items application
        CROSS JOIN LATERAL fn_subcontract_draw_edges(application.goods_id) edge
        WHERE application.id = ANY(p_application_items) AND NOT application.is_deleted
    ), pools AS MATERIALIZED (
        SELECT pool.* FROM fn_subcontract_kit_pool_facts((
            SELECT COALESCE(jsonb_agg(jsonb_build_object('goods_id', dimension.component_goods_id,
                'color_id', dimension.color_id, 'application_item_id', dimension.application_item_id)), '[]'::jsonb)
            FROM (SELECT DISTINCT edges.component_goods_id, edges.color_id, edges.application_item_id FROM edges) dimension
        ), p_exclude_order) pool
    )
    SELECT edge.application_item_id, edge.edge_id, edge.component_goods_id, edge.color_id, edge.sort_order,
           edge.bom_unit_qty, pool.exact_qty, pool.demand_qty, pool.exact_free_qty, pool.public_qty,
           pool.public_claimed_qty, pool.public_free_qty, pool.exact_free_qty + pool.public_free_qty,
           COALESCE(fn_subcontract_draw_sets(pool.exact_free_qty + pool.public_free_qty, edge.bom_unit_qty), 0)
    FROM edges edge JOIN pools pool ON pool.goods_id = edge.component_goods_id
     AND pool.color_id IS NOT DISTINCT FROM edge.color_id AND pool.application_item_id = edge.application_item_id
$function$;

CREATE FUNCTION fn_subcontract_application_orderable_batch(p_application_items UUID[])
RETURNS TABLE(application_item_id UUID, open_qty NUMERIC, orderable_qty NUMERIC)
LANGUAGE sql STABLE
AS $function$
    WITH applications AS MATERIALIZED (
        SELECT item.id, fn_subcontract_application_open_qty(item.id) AS open_qty
        FROM subcontract_application_items item WHERE item.id = ANY(p_application_items)
    ), kits AS MATERIALIZED (
        SELECT fact.application_item_id, MIN(fact.kit_qty) AS kit_qty
        FROM fn_subcontract_application_kit_facts_batch(
            ARRAY(SELECT application.id FROM applications application WHERE application.open_qty > 0), NULL) fact
        GROUP BY fact.application_item_id
    )
    SELECT application.id, application.open_qty,
           CASE WHEN application.open_qty > 0 THEN LEAST(application.open_qty, COALESCE(kit.kit_qty, 0)) ELSE 0 END
    FROM applications application LEFT JOIN kits kit ON kit.application_item_id = application.id
$function$;

CREATE OR REPLACE FUNCTION fn_subcontract_component_pool_demands(p_goods UUID, p_color UUID, p_exclude_order UUID)
RETURNS TABLE(application_item_id UUID, demand_qty NUMERIC) LANGUAGE sql STABLE
AS $function$
    SELECT demand.application_item_id, demand.demand_qty
    FROM fn_subcontract_component_pool_demands_batch(
        jsonb_build_array(jsonb_build_object('goods_id', p_goods, 'color_id', p_color)), p_exclude_order, NULL) demand
$function$;

CREATE OR REPLACE FUNCTION fn_subcontract_component_public_free(p_goods UUID, p_color UUID, p_exclude_order UUID)
RETURNS TABLE(public_qty NUMERIC, claimed_qty NUMERIC, free_qty NUMERIC) LANGUAGE sql STABLE
AS $function$
    SELECT COALESCE(MAX(pool.public_qty), 0), COALESCE(MAX(pool.public_claimed_qty), 0),
           COALESCE(MAX(pool.public_free_qty), 0)
    FROM fn_subcontract_kit_pool_facts(
        jsonb_build_array(jsonb_build_object('goods_id', p_goods, 'color_id', p_color)), p_exclude_order) pool
    WHERE pool.application_item_id IS NULL
$function$;

CREATE OR REPLACE FUNCTION fn_subcontract_application_kit_facts(p_application_item UUID, p_exclude_order UUID)
RETURNS TABLE(edge_id UUID, component_goods_id UUID, color_id UUID, sort_order INTEGER, bom_unit_qty NUMERIC,
              exact_qty NUMERIC, exact_claimed_qty NUMERIC, exact_free_qty NUMERIC,
              public_qty NUMERIC, public_claimed_qty NUMERIC, public_free_qty NUMERIC, free_qty NUMERIC, kit_qty NUMERIC)
LANGUAGE sql STABLE
AS $function$
    SELECT fact.edge_id, fact.component_goods_id, fact.color_id, fact.sort_order, fact.bom_unit_qty,
           fact.exact_qty, fact.exact_claimed_qty, fact.exact_free_qty, fact.public_qty,
           fact.public_claimed_qty, fact.public_free_qty, fact.free_qty, fact.kit_qty
    FROM fn_subcontract_application_kit_facts_batch(ARRAY[p_application_item], p_exclude_order) fact
$function$;

CREATE OR REPLACE FUNCTION fn_subcontract_application_kit_qty(p_application_item UUID, p_exclude_order UUID)
RETURNS NUMERIC LANGUAGE sql STABLE
AS $function$
    SELECT COALESCE(MIN(fact.kit_qty), 0)
    FROM fn_subcontract_application_kit_facts_batch(ARRAY[p_application_item], p_exclude_order) fact
$function$;

CREATE OR REPLACE FUNCTION fn_subcontract_application_orderable_qty(p_application_item UUID)
RETURNS NUMERIC LANGUAGE sql STABLE
AS $function$
    SELECT COALESCE((SELECT quantity.orderable_qty
                    FROM fn_subcontract_application_orderable_batch(ARRAY[p_application_item]) quantity), 0)
$function$;

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
        SELECT demand.* FROM fn_subcontract_component_pool_demands_batch(
            (SELECT COALESCE(jsonb_agg(to_jsonb(dimension)), '[]'::jsonb) FROM dimensions dimension), NULL, p_order) demand
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

COMMENT ON FUNCTION fn_subcontract_component_pool_demands_batch(jsonb, uuid, uuid) IS
    'V868: authoritative set-based source shares; one materialized component need per relevant live order/dimension.';
COMMENT ON FUNCTION fn_subcontract_application_orderable_batch(uuid[]) IS
    'V868: batch kit/open projection, preserving V854 latest financial-attempt commitments and global material pools.';
