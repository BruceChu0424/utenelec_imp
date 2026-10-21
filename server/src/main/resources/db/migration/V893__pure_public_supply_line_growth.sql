-- ADR-099 / V640: an unordered external request grows in place, including
-- a legitimate pure-public aggregate batch with no private allocation row.
-- Preserve the V712 MAKE append-ready branch and the original private path.
-- Public-only safety, ordered/stopped/closed/deleted, transferred or claimed
-- sources remain outside this narrow additional admission path.
CREATE OR REPLACE FUNCTION fn_preplan_supply_action_growable(p_action UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT fn_aggregate_batch_append_ready(p_action) OR EXISTS (
        SELECT 1
        FROM preplan_supply_actions action
        WHERE action.id = p_action
          AND action.operation_type = 'SUPPLY'
          AND action.status = 'CREATED'
          AND action.route IN ('BUY', 'SUBCONTRACT')
          AND action.external_document_type IN ('PURCHASE_REQUEST', 'SUBCONTRACT_APPLICATION')
          AND NOT fn_preplan_action_has_future_transfer(action.id)
          AND NOT fn_preplan_action_has_shared_claims(action.id)
          AND (
              EXISTS (
                  SELECT 1 FROM preplan_supply_action_allocations allocation
                  WHERE allocation.action_id = action.id
                    AND allocation.external_item_id IS NOT NULL)
              OR (
                  action.requested_qty = 0
                  AND action.public_surplus_qty > 0
                  AND action.safety_replenishment_qty = 0
                  AND NOT EXISTS (
                      SELECT 1 FROM preplan_supply_action_allocations allocation
                      WHERE allocation.action_id = action.id)
                  AND (
                      (action.route = 'BUY'
                       AND action.external_document_type = 'PURCHASE_REQUEST'
                       AND EXISTS (
                           SELECT 1 FROM purchase_request_items item
                           WHERE item.id = action.public_surplus_external_item_id
                             AND item.request_id = action.external_document_id
                             AND NOT item.is_deleted))
                      OR
                      (action.route = 'SUBCONTRACT'
                       AND action.external_document_type = 'SUBCONTRACT_APPLICATION'
                       AND EXISTS (
                           SELECT 1 FROM subcontract_application_items item
                           WHERE item.id = action.public_surplus_external_item_id
                             AND item.application_id = action.external_document_id
                             AND NOT item.is_deleted))
                  )
              )
          )
          AND NOT EXISTS (
              SELECT 1 FROM preplan_supply_action_allocations allocation
              WHERE allocation.action_id = action.id
                AND allocation.external_item_id IS NOT NULL
                AND NOT fn_preplan_external_item_unordered(action.route, allocation.external_item_id))
          AND (action.public_surplus_external_item_id IS NULL
               OR fn_preplan_external_item_unordered(action.route, action.public_surplus_external_item_id))
    )
$$;

COMMENT ON FUNCTION fn_preplan_supply_action_growable(UUID) IS
    'ADR-099: preserve MAKE/private admission; also allow a live same-document pure-public BUY/SUBCONTRACT source with zero private demand and no safety, orders, transfers or claims to grow in place';
