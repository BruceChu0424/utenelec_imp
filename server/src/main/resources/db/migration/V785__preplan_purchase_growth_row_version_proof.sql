-- V785: V781 request-item CAS metadata must not invalidate V640's existing
-- proof for an unordered request line growing in place. Source identity,
-- quantity growth, action ownership and unordered-state checks stay intact.
-- No trigger is disabled and no historical quantity or version is rewritten.

CREATE OR REPLACE FUNCTION public.fn_is_preplan_supply_line_growth(p_table TEXT, p_old JSONB, p_new JSONB)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT p_table IN ('purchase_request_items', 'subcontract_application_items')
       AND CASE WHEN p_table = 'purchase_request_items' THEN
           -- V781 generates exactly one new version for this UPDATE. It is not
           -- source identity, but its progression must still be proven.
           (p_old - ARRAY['qty', 'updated_at', 'updated_by', 'row_version'])
               IS NOT DISTINCT FROM (p_new - ARRAY['qty', 'updated_at', 'updated_by', 'row_version'])
           AND (p_new->>'row_version')::bigint = (p_old->>'row_version')::bigint + 1
       ELSE
           (p_old - ARRAY['qty', 'updated_at', 'updated_by'])
               IS NOT DISTINCT FROM (p_new - ARRAY['qty', 'updated_at', 'updated_by'])
       END
       AND (p_new->>'qty')::numeric > (p_old->>'qty')::numeric
       AND EXISTS (
           SELECT 1
           FROM preplan_supply_actions action
           LEFT JOIN preplan_supply_action_allocations allocation
             ON allocation.action_id = action.id
           WHERE action.route = CASE p_table WHEN 'purchase_request_items' THEN 'BUY' ELSE 'SUBCONTRACT' END
             AND (allocation.external_item_id = (p_old->>'id')::uuid
                  OR action.public_surplus_external_item_id = (p_old->>'id')::uuid)
             AND fn_preplan_supply_action_growable(action.id))
$$;

COMMENT ON FUNCTION fn_is_preplan_supply_line_growth(TEXT, JSONB, JSONB) IS
    'ADR-099：申请明细只增 qty 且被仍可就地追加的供给行动锚定时，生产联动守卫放行这次改量';
