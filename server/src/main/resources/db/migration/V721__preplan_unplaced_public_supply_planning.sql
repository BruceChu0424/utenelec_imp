-- Public supply is usable for planning as soon as the analysis has issued a
-- real request. It is still not physical stock or an approved vendor order.
-- Keep the existing approved/receipt functions unchanged: inventory allocation
-- and valuation must continue to depend on actual approved receipts.
CREATE OR REPLACE FUNCTION fn_preplan_public_source_unplaced_qty(p_action UUID,p_item UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    WITH source AS (
        SELECT * FROM preplan_supply_actions
        WHERE id=p_action AND operation_type='SUPPLY' AND status<>'CANCELLED'
    ), request AS (
        SELECT item.qty*COALESCE(item.unit_rate,1) qty
        FROM source JOIN purchase_request_items item ON item.id=p_item
        JOIN purchase_requests header ON header.id=item.request_id
        WHERE source.route='BUY' AND header.id=source.external_document_id
          AND header.status=1 AND NOT header.is_deleted AND NOT header.is_closed
          AND NOT header.is_stopped AND NOT item.is_deleted
        UNION ALL
        SELECT item.qty*COALESCE(item.unit_rate,1)
        FROM source JOIN subcontract_application_items item ON item.id=p_item
        JOIN subcontract_applications header ON header.id=item.application_id
        WHERE source.route='SUBCONTRACT' AND header.id=source.external_document_id
          AND header.status=1 AND NOT header.is_deleted AND NOT header.is_closed
          AND NOT item.is_deleted
    ), ordered AS (
        SELECT fn_purchase_order_source_share(item.id,link.request_item_id,
                   item.qty*COALESCE(item.unit_rate,1)) qty
        FROM source JOIN purchase_order_item_sources link ON link.request_item_id=p_item
        JOIN purchase_order_items item ON item.id=link.order_item_id
        JOIN purchase_orders header ON header.id=item.order_id
        WHERE source.route='BUY' AND header.status=1 AND NOT header.is_deleted AND NOT item.is_deleted
        UNION ALL
        SELECT fn_subcontract_order_source_share(item.id,link.application_item_id,
                   item.qty*COALESCE(item.unit_rate,1))
        FROM source JOIN subcontract_order_item_sources link ON link.application_item_id=p_item
        JOIN subcontract_order_items item ON item.id=link.order_item_id
        JOIN subcontract_orders header ON header.id=item.order_id
        WHERE source.route='SUBCONTRACT' AND header.status=1 AND NOT header.is_deleted AND NOT item.is_deleted
    )
    SELECT GREATEST(COALESCE((SELECT sum(qty) FROM request),0)
        -COALESCE((SELECT sum(qty) FROM ordered),0),0)
$$;

CREATE OR REPLACE FUNCTION fn_preplan_public_source_planning_capacity(p_action UUID,p_item UUID)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE source preplan_supply_actions%ROWTYPE; source_limit NUMERIC; pending NUMERIC;
        private_baseline NUMERIC:=0; request_qty NUMERIC:=0;
BEGIN
    SELECT * INTO source FROM preplan_supply_actions WHERE id=p_action;
    IF source.id IS NULL OR source.status='CANCELLED' THEN RETURN 0; END IF;
    SELECT COALESCE(max(source_limit_qty),0) INTO source_limit
    FROM v_preplan_public_supply_sources_v474 WHERE source_action_id=p_action AND external_item_id=p_item;
    pending:=fn_preplan_public_source_unplaced_qty(p_action,p_item);
    IF pending<=0 THEN RETURN fn_preplan_public_source_approved_capacity(p_action,p_item); END IF;
    IF EXISTS(SELECT 1 FROM preplan_supply_action_allocations WHERE action_id=p_action AND external_item_id=p_item) THEN
        private_baseline:=GREATEST(source.requested_qty-fn_preplan_future_public_release_qty(p_action,p_item),0);
    ELSIF source.safety_external_item_id=p_item THEN private_baseline:=source.safety_replenishment_qty;
    END IF;
    IF source.route='BUY' THEN
        SELECT qty*COALESCE(unit_rate,1) INTO request_qty FROM purchase_request_items WHERE id=p_item;
    ELSE
        SELECT qty*COALESCE(unit_rate,1) INTO request_qty FROM subcontract_application_items WHERE id=p_item;
    END IF;
    RETURN LEAST(source_limit,GREATEST(COALESCE(request_qty,0)-private_baseline,
        fn_preplan_public_source_approved_capacity(p_action,p_item),0));
END;
$$;

CREATE OR REPLACE FUNCTION fn_preplan_public_source_planning_open_qty(p_action UUID,p_item UUID)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE source preplan_supply_actions%ROWTYPE; private_open NUMERIC:=0;
BEGIN
    SELECT * INTO source FROM preplan_supply_actions WHERE id=p_action;
    IF source.id IS NULL OR source.status='CANCELLED' THEN RETURN 0; END IF;
    IF EXISTS(SELECT 1 FROM preplan_supply_action_allocations WHERE action_id=p_action AND external_item_id=p_item) THEN
        private_open:=fn_preplan_public_source_private_open_qty(p_action,p_item);
    ELSIF source.safety_external_item_id=p_item THEN private_open:=source.safety_replenishment_qty;
    END IF;
    RETURN LEAST(fn_preplan_public_source_planning_capacity(p_action,p_item),
        GREATEST(fn_preplan_external_expected_qty(p_action,p_item)
            +fn_preplan_public_source_unplaced_qty(p_action,p_item)-private_open,0));
END;
$$;

-- Preserve the public view's original columns and their approved semantics.
-- Only its claimable remainder changes; append explicit planning columns.
DO $planning_view$
DECLARE definition TEXT; marker TEXT;
BEGIN
    SELECT rtrim(pg_get_viewdef('v_preplan_public_surplus_source_state'::regclass,true),E';\n\r ')
      INTO definition;
    -- The inner legacy view still supplies approved quantities and exact claim
    -- history. Calculate the broader budget from the same source/item identity.
    EXECUTE 'CREATE OR REPLACE VIEW v_preplan_public_surplus_source_state AS WITH legacy AS ('
      || definition || '), planning AS (
          SELECT legacy.*,
            fn_preplan_public_source_planning_capacity(source_action_id,claim_external_item_id) planning_capacity_qty,
            fn_preplan_public_source_planning_open_qty(source_action_id,claim_external_item_id) planning_open_qty
          FROM legacy)
        SELECT source_action_id,source_analysis_id,warehouse_id,goods_id,color_id,unit_id,
          route,external_document_type,external_document_id,external_document_no,claim_external_item_id,
          approved_capacity_qty,approved_open_qty,claimed_qty,claim_open_qty,
          LEAST(GREATEST(planning_capacity_qty-claimed_qty,0),
                GREATEST(planning_open_qty-claim_open_qty,0))::numeric available_to_claim_qty,
          expected_date,created_at,planning_capacity_qty,planning_open_qty,
          GREATEST(planning_open_qty-approved_open_qty,0)::numeric unplaced_open_qty
        FROM planning';
END;
$planning_view$;

DO $planning_claim_guards$
DECLARE definition TEXT; signature TEXT;
BEGIN
    FOREACH signature IN ARRAY ARRAY['fn_validate_preplan_shared_future_claim()',
                                      'fn_preplan_shared_action_pending_qty(uuid)'] LOOP
        SELECT pg_get_functiondef(signature::regprocedure) INTO definition;
        IF strpos(definition,'fn_preplan_public_source_open_qty')=0 THEN
            RAISE EXCEPTION 'V721 public claim open contract changed: %',signature;
        END IF;
        definition:=replace(definition,'fn_preplan_public_source_open_qty','fn_preplan_public_source_planning_open_qty');
        definition:=replace(definition,'fn_preplan_public_source_approved_capacity','fn_preplan_public_source_planning_capacity');
        EXECUTE definition;
    END LOOP;
    -- A request claimed before commercial ordering must be allowed to become
    -- an approved order. Reversal/deletion/early closure remain guarded.
    FOREACH signature IN ARRAY ARRAY['fn_guard_purchase_shared_future_source_header()',
                                      'fn_guard_subcontract_shared_future_source_header()'] LOOP
        SELECT pg_get_functiondef(signature::regprocedure) INTO definition;
        IF strpos(definition,'NEW.status IS DISTINCT FROM OLD.status')=0 THEN
            RAISE EXCEPTION 'V721 source approval guard changed: %',signature;
        END IF;
        EXECUTE replace(definition,'NEW.status IS DISTINCT FROM OLD.status',
            '(NEW.status IS DISTINCT FROM OLD.status AND NOT (OLD.status=0 AND NEW.status=1))');
    END LOOP;
END;
$planning_claim_guards$;
