-- V569 was already applied with checksum 1405930679. Its original bytes are
-- restored; all later reviewed supply/receipt/cancellation changes move here.
-- No existing fact row, original commercial quantity, or Flyway history is updated.
-- Historical cancellations had one meaning: qty restored to the original owner.
-- Their new fields stay NULL/NULL; the restored-quantity helper derives that
-- original meaning. New writes must persist an explicit non-negative split.
ALTER TABLE preplan_future_supply_transfer_cancellations
    ADD COLUMN restore_to_source_qty NUMERIC(18,4),
    ADD COLUMN public_release_qty NUMERIC(18,4),
    ADD CONSTRAINT preplan_future_cancel_split_check CHECK (
      (restore_to_source_qty IS NULL AND public_release_qty IS NULL)
      OR (restore_to_source_qty IS NOT NULL AND public_release_qty IS NOT NULL
        AND restore_to_source_qty>=0 AND public_release_qty>=0
        AND qty=restore_to_source_qty+public_release_qty));

CREATE OR REPLACE FUNCTION fn_preplan_future_transfer_cancelled_qty(p_transfer UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(qty),0) FROM preplan_future_supply_transfer_cancellations WHERE transfer_id=p_transfer
$$;

CREATE OR REPLACE FUNCTION fn_preplan_future_transfer_restored_qty(p_transfer UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(COALESCE(restore_to_source_qty,qty)),0) FROM preplan_future_supply_transfer_cancellations WHERE transfer_id=p_transfer
$$;

CREATE OR REPLACE FUNCTION fn_preplan_allocation_received_qty(p_allocation UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT fn_preplan_allocation_effective_exact_qty(p_allocation)+COALESCE((
      SELECT sum(CASE WHEN output.event_kind='FULFILL' THEN output.qty_base ELSE -output.qty_base END)
      FROM preplan_root_output_events output JOIN preplan_analysis_stock_exact_pegs exact ON exact.stock_reservation_id=output.source_reservation_id
      WHERE exact.supply_action_allocation_id=p_allocation),0)
$$;

CREATE OR REPLACE FUNCTION fn_preplan_action_received_qty(p_action UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(fn_preplan_allocation_received_qty(id)),0) FROM preplan_supply_action_allocations WHERE action_id=p_action
$$;

CREATE OR REPLACE FUNCTION fn_preplan_future_transfer_received_qty(p_transfer UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT fn_preplan_allocation_received_qty(target_allocation_id)
      FROM preplan_future_supply_transfers WHERE id=p_transfer),0)
$$;

CREATE OR REPLACE FUNCTION fn_preplan_allocation_admitted_qty(p_allocation UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT GREATEST(allocation.allocated_qty
      -COALESCE((SELECT sum(transfer.qty-fn_preplan_future_transfer_restored_qty(transfer.id))
          FROM preplan_future_supply_transfers transfer WHERE transfer.source_allocation_id=allocation.id),0)
      -COALESCE((SELECT fn_preplan_future_transfer_cancelled_qty(transfer.id)
          FROM preplan_future_supply_transfers transfer WHERE transfer.target_allocation_id=allocation.id),0),0)
      FROM preplan_supply_action_allocations allocation WHERE allocation.id=p_allocation),0)
$$;

CREATE OR REPLACE FUNCTION fn_preplan_action_admitted_qty(p_action UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT sum(fn_preplan_allocation_admitted_qty(id)) FROM preplan_supply_action_allocations
        WHERE action_id=p_action),(SELECT requested_qty FROM preplan_supply_actions WHERE id=p_action),0)
$$;

CREATE OR REPLACE FUNCTION fn_preplan_action_has_future_transfer(p_action UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM preplan_future_supply_transfers transfer
      JOIN preplan_supply_action_allocations source ON source.id=transfer.source_allocation_id
      WHERE transfer.target_action_id=p_action OR source.action_id=p_action
        AND transfer.qty>fn_preplan_future_transfer_restored_qty(transfer.id))
$$;

CREATE OR REPLACE FUNCTION fn_preplan_external_exact_approved_qty(p_action UUID,p_external UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT sum(GREATEST(source.base_qty-COALESCE(fn_preplan_order_public_source_qty(action.id,p_external,source.kind,source.order_id),0),0))
      FROM preplan_supply_actions action CROSS JOIN LATERAL (
        SELECT 'PURCHASE'::text kind,item.order_id,fn_purchase_order_source_share(item.id,link.request_item_id,item.qty*COALESCE(item.unit_rate,1)) base_qty
        FROM purchase_order_item_sources link JOIN purchase_order_items item ON item.id=link.order_item_id AND NOT item.is_deleted
        JOIN purchase_orders header ON header.id=item.order_id AND header.status=1 AND NOT header.is_deleted
        WHERE action.route='BUY' AND link.request_item_id=p_external
        UNION ALL
        SELECT 'SUBCONTRACT',item.order_id,fn_subcontract_order_source_share(item.id,link.application_item_id,item.qty*COALESCE(item.unit_rate,1))
        FROM subcontract_order_item_sources link JOIN subcontract_order_items item ON item.id=link.order_item_id AND NOT item.is_deleted
        JOIN subcontract_orders header ON header.id=item.order_id AND header.status=1 AND NOT header.is_deleted
        WHERE action.route='SUBCONTRACT' AND link.application_item_id=p_external
      ) source WHERE action.id=p_action AND action.operation_type='SUPPLY' AND action.status<>'CANCELLED'),0)
$$;

CREATE OR REPLACE FUNCTION fn_preplan_future_source_private_capacity_qty(p_allocation UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT GREATEST(LEAST(allocation.allocated_qty,
      -- Recover the original private basis before subtracting outgoing/private
      -- public releases below, so a release is never deducted twice.
      GREATEST(fn_preplan_external_exact_approved_qty(action.id,allocation.external_item_id)
        +COALESCE((SELECT sum(cancel.public_release_qty)
          FROM preplan_future_supply_transfers transfer
          JOIN preplan_supply_action_allocations origin ON origin.id=transfer.source_allocation_id
          JOIN preplan_future_supply_transfer_cancellations cancel ON cancel.transfer_id=transfer.id
          WHERE origin.action_id=action.id AND transfer.external_item_id=allocation.external_item_id),0)-COALESCE((
        SELECT sum(prior.allocated_qty) FROM preplan_supply_action_allocations prior
        JOIN preplan_supply_actions prior_action ON prior_action.id=prior.action_id AND prior_action.operation_type='SUPPLY' AND prior_action.status<>'CANCELLED'
        WHERE prior.external_item_id=allocation.external_item_id AND (prior.created_at,prior.id)<(allocation.created_at,allocation.id)),0),0))
      -fn_preplan_allocation_received_qty(allocation.id)
      -(allocation.allocated_qty-fn_preplan_allocation_admitted_qty(allocation.id)),0)
      FROM preplan_supply_action_allocations allocation JOIN preplan_supply_actions action ON action.id=allocation.action_id
      WHERE allocation.id=p_allocation AND action.operation_type='SUPPLY' AND action.status<>'CANCELLED'
        AND action.route IN('BUY','SUBCONTRACT') AND allocation.external_item_id IS NOT NULL
        AND (action.route='BUY' OR NOT EXISTS(SELECT 1 FROM goods_bom_items bom WHERE bom.goods_id=action.goods_id AND NOT bom.is_deleted))),0)
$$;

CREATE OR REPLACE VIEW v_preplan_future_supply_transfer_state AS
SELECT transfer.*,fn_preplan_future_transfer_cancelled_qty(transfer.id)::numeric cancelled_qty,
       fn_preplan_future_transfer_received_qty(transfer.id)::numeric received_qty,
       GREATEST(transfer.qty-fn_preplan_future_transfer_cancelled_qty(transfer.id)-fn_preplan_future_transfer_received_qty(transfer.id),0)::numeric remaining_qty,
       CASE WHEN fn_preplan_future_transfer_cancelled_qty(transfer.id)=transfer.qty THEN 'CANCELLED'
            WHEN fn_preplan_future_transfer_received_qty(transfer.id)+fn_preplan_future_transfer_cancelled_qty(transfer.id)>=transfer.qty THEN 'RECEIVED'
            WHEN fn_preplan_future_transfer_received_qty(transfer.id)>0 THEN 'PARTIAL' ELSE 'WAITING_RECEIPT' END status
FROM preplan_future_supply_transfers transfer;

CREATE OR REPLACE FUNCTION fn_guard_preplan_future_transfer() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source preplan_supply_action_allocations%ROWTYPE; source_action preplan_supply_actions%ROWTYPE;
        target production_material_analysis_materials%ROWTYPE; source_material production_material_analysis_materials%ROWTYPE;
        cancelled NUMERIC; received NUMERIC; transfer preplan_future_supply_transfers%ROWTYPE;
BEGIN
    IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Future supply transfer history is append-only' USING ERRCODE='55000'; END IF;
    IF TG_TABLE_NAME='preplan_future_supply_transfer_cancellations' THEN
        -- NULL/NULL is reserved for rows already present when V571 added the
        -- columns. Never invent a split or accept this legacy shape on INSERT.
        IF NEW.restore_to_source_qty IS NULL OR NEW.public_release_qty IS NULL THEN
            RAISE EXCEPTION 'New future cancellation requires an explicit restoration/public split' USING ERRCODE='23514';
        END IF;
        SELECT * INTO transfer FROM preplan_future_supply_transfers WHERE id=NEW.transfer_id FOR UPDATE;
        PERFORM id FROM preplan_supply_action_allocations WHERE id IN(transfer.source_allocation_id,transfer.target_allocation_id) ORDER BY id FOR UPDATE;
        cancelled:=fn_preplan_future_transfer_cancelled_qty(transfer.id);received:=fn_preplan_future_transfer_received_qty(transfer.id);
        IF transfer.id IS NULL OR NEW.qty>transfer.qty-cancelled-received THEN
            RAISE EXCEPTION 'Only the unreceived future transfer remainder may be cancelled' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    SELECT * INTO source FROM preplan_supply_action_allocations WHERE id=NEW.source_allocation_id FOR UPDATE;
    SELECT * INTO source_action FROM preplan_supply_actions WHERE id=source.action_id FOR UPDATE;
    SELECT * INTO source_material FROM production_material_analysis_materials WHERE id=source.analysis_material_id;
    SELECT * INTO target FROM production_material_analysis_materials WHERE id=NEW.target_material_id;
    IF source.id IS NULL OR source.analysis_id<>NEW.source_analysis_id OR source.analysis_material_id<>NEW.source_material_id
      OR source.external_item_id IS DISTINCT FROM NEW.external_item_id OR source_action.operation_type<>'SUPPLY'
      OR source_action.status='CANCELLED' OR source_action.route NOT IN('BUY','SUBCONTRACT')
      OR target.id IS NULL OR target.analysis_id<>NEW.target_analysis_id OR NOT target.active OR NOT source_material.active
      OR (target.goods_id,target.color_id,target.unit_id) IS DISTINCT FROM (source_material.goods_id,source_material.color_id,source_material.unit_id)
      OR target.confirmed_route IS DISTINCT FROM source_action.route
      OR NOT EXISTS(SELECT 1 FROM production_material_analyses a JOIN production_material_analyses b ON b.id=NEW.target_analysis_id
          WHERE a.id=NEW.source_analysis_id AND NOT a.is_deleted AND NOT b.is_deleted
            AND a.status IN('ACTIVE','PARTIALLY_PLANNED','COMPLETED') AND b.status IN('ACTIVE','PARTIALLY_PLANNED','COMPLETED')
            AND fn_warehouse_same_main(a.warehouse_id,b.warehouse_id))
      OR NEW.qty>fn_preplan_future_source_available_qty(source.id)
      OR (NEW.target_need_date IS NOT NULL AND (NEW.expected_date IS NULL OR NEW.expected_date>NEW.target_need_date) AND NOT NEW.allow_late_supply) THEN
        RAISE EXCEPTION 'Future transfer source, scope, timing or unreceived capacity is invalid' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION fn_assert_preplan_future_transfer() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE transfer preplan_future_supply_transfers%ROWTYPE; source preplan_supply_action_allocations%ROWTYPE;
BEGIN
    IF TG_TABLE_NAME='preplan_future_supply_transfers' THEN transfer:=NEW;
    ELSE SELECT * INTO transfer FROM preplan_future_supply_transfers WHERE id=NEW.transfer_id; END IF;
    SELECT * INTO source FROM preplan_supply_action_allocations WHERE id=transfer.source_allocation_id;
    IF NOT EXISTS(SELECT 1 FROM preplan_supply_actions action JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id
      JOIN preplan_supply_actions origin ON origin.id=source.action_id
      WHERE action.id=transfer.target_action_id AND allocation.id=transfer.target_allocation_id
        AND action.operation_type='FUTURE_TRANSFER' AND action.claim_source_action_id=source.action_id
        AND action.analysis_id=transfer.target_analysis_id AND allocation.analysis_id=transfer.target_analysis_id
        AND allocation.analysis_material_id=transfer.target_material_id AND allocation.external_item_id=transfer.external_item_id
        AND allocation.allocated_qty=transfer.qty AND action.requested_qty=transfer.qty
        AND (action.route,action.external_document_type,action.external_document_id,action.goods_id,action.color_id,action.unit_id)
            IS NOT DISTINCT FROM (origin.route,origin.external_document_type,origin.external_document_id,origin.goods_id,origin.color_id,origin.unit_id))
      OR fn_preplan_allocation_admitted_qty(source.id)<fn_preplan_allocation_received_qty(source.id)
      OR transfer.qty<fn_preplan_future_transfer_cancelled_qty(transfer.id)+fn_preplan_future_transfer_received_qty(transfer.id) THEN
        RAISE EXCEPTION 'Future transfer must conserve original and target allocation quantities and real receipts' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION fn_guard_future_transfer_action() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='INSERT' AND NEW.operation_type='FUTURE_TRANSFER' AND NOT EXISTS(
        SELECT 1 FROM preplan_future_supply_transfers transfer JOIN preplan_supply_action_allocations source ON source.id=transfer.source_allocation_id
        WHERE transfer.target_action_id=NEW.id AND transfer.target_analysis_id=NEW.analysis_id
          AND transfer.qty=NEW.requested_qty AND source.action_id=NEW.claim_source_action_id) THEN
        RAISE EXCEPTION 'Private future allocation requires an immutable transfer proof' USING ERRCODE='23514';
    END IF;
    IF TG_OP='UPDATE' AND NEW.status='CANCELLED' AND OLD.status<>'CANCELLED' AND EXISTS(
        SELECT 1 FROM preplan_future_supply_transfers transfer JOIN preplan_supply_action_allocations source ON source.id=transfer.source_allocation_id
        WHERE source.action_id=OLD.id AND transfer.qty>fn_preplan_future_transfer_cancelled_qty(transfer.id)) THEN
        RAISE EXCEPTION 'Source supply has active private future transfers; settle or cancel the unreceived transfers first' USING ERRCODE='23514';
    END IF;
    IF TG_OP='UPDATE' AND NEW.operation_type='FUTURE_TRANSFER' AND NEW.status='CANCELLED' AND EXISTS(
        SELECT 1 FROM preplan_future_supply_transfers transfer WHERE transfer.target_action_id=NEW.id
          AND transfer.qty>fn_preplan_future_transfer_cancelled_qty(transfer.id)) THEN
        RAISE EXCEPTION 'Cancel a private future transfer through its unreceived cancellation ledger' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION fn_future_external_has_transfers(p_external UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM preplan_future_supply_transfers transfer
      WHERE transfer.external_item_id=p_external AND transfer.qty>fn_preplan_future_transfer_cancelled_qty(transfer.id))
$$;

CREATE OR REPLACE FUNCTION fn_guard_future_transfer_source_lifecycle() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE affected BOOLEAN:=FALSE; item_id UUID; header_id UUID; external UUID;
BEGIN
    IF TG_TABLE_NAME='production_material_analyses' THEN
        IF NEW.status<>'CANCELLED' AND NOT NEW.is_deleted THEN RETURN NEW; END IF;
        affected:=EXISTS(SELECT 1 FROM preplan_future_supply_transfers transfer
            WHERE OLD.id IN(transfer.source_analysis_id,transfer.target_analysis_id)
              AND transfer.qty>fn_preplan_future_transfer_cancelled_qty(transfer.id));
    ELSIF TG_TABLE_NAME='purchase_requests' OR TG_TABLE_NAME='subcontract_applications' THEN
        IF TG_OP='UPDATE' AND NEW.status>=0 AND NOT NEW.is_deleted
            AND NOT COALESCE((to_jsonb(NEW)->>'is_stopped')::boolean,FALSE) THEN RETURN NEW; END IF;
        affected:=EXISTS(SELECT 1 FROM preplan_future_supply_transfers transfer
            JOIN preplan_supply_action_allocations allocation ON allocation.id=transfer.source_allocation_id
            JOIN preplan_supply_actions action ON action.id=allocation.action_id
            WHERE action.external_document_id=OLD.id AND transfer.qty>fn_preplan_future_transfer_cancelled_qty(transfer.id));
    ELSIF TG_TABLE_NAME IN('purchase_order_item_sources','subcontract_order_item_sources') THEN
        item_id:=CASE WHEN TG_OP='DELETE' THEN OLD.order_item_id ELSE NEW.order_item_id END;
        IF TG_TABLE_NAME='purchase_order_item_sources' THEN
            affected:=EXISTS(SELECT 1 FROM purchase_order_item_sources source
                WHERE source.order_item_id=item_id AND fn_future_external_has_transfers(source.request_item_id));
        ELSE
            affected:=EXISTS(SELECT 1 FROM subcontract_order_item_sources source
                WHERE source.order_item_id=item_id AND fn_future_external_has_transfers(source.application_item_id));
        END IF;
        IF TG_OP<>'INSERT' THEN
            external:=CASE WHEN TG_TABLE_NAME='purchase_order_item_sources' THEN (to_jsonb(OLD)->>'request_item_id')::uuid ELSE (to_jsonb(OLD)->>'application_item_id')::uuid END;
            affected:=affected OR fn_future_external_has_transfers(external);
        END IF;
    ELSIF TG_TABLE_NAME IN('purchase_order_items','subcontract_order_items') THEN
        IF TG_OP='UPDATE' AND (NEW.qty,NEW.unit_rate,NEW.goods_id,NEW.color_id,NEW.unit_id,NEW.order_id,NEW.is_deleted)
             IS NOT DISTINCT FROM (OLD.qty,OLD.unit_rate,OLD.goods_id,OLD.color_id,OLD.unit_id,OLD.order_id,OLD.is_deleted) THEN RETURN NEW; END IF;
        item_id:=OLD.id;
        IF TG_TABLE_NAME='purchase_order_items' THEN
            affected:=EXISTS(SELECT 1 FROM purchase_order_item_sources source WHERE source.order_item_id=item_id AND fn_future_external_has_transfers(source.request_item_id));
        ELSE
            affected:=EXISTS(SELECT 1 FROM subcontract_order_item_sources source WHERE source.order_item_id=item_id AND fn_future_external_has_transfers(source.application_item_id));
        END IF;
    ELSIF TG_TABLE_NAME IN('purchase_orders','subcontract_orders') THEN
        IF NEW.status IS NOT DISTINCT FROM OLD.status AND NEW.is_deleted IS NOT DISTINCT FROM OLD.is_deleted
          AND NOT(NEW.is_closed AND NOT OLD.is_closed) THEN RETURN NEW; END IF;
        header_id:=OLD.id;
        IF TG_TABLE_NAME='purchase_orders' THEN
            affected:=EXISTS(SELECT 1 FROM purchase_order_items item JOIN purchase_order_item_sources source ON source.order_item_id=item.id
              WHERE item.order_id=header_id AND fn_future_external_has_transfers(source.request_item_id)
                AND (NEW.status<>OLD.status OR NEW.is_deleted<>OLD.is_deleted OR item.qty-item.received_qty+item.returned_qty>0));
        ELSE
            affected:=EXISTS(SELECT 1 FROM subcontract_order_items item JOIN subcontract_order_item_sources source ON source.order_item_id=item.id
              WHERE item.order_id=header_id AND fn_future_external_has_transfers(source.application_item_id)
                AND (NEW.status<>OLD.status OR NEW.is_deleted<>OLD.is_deleted OR item.qty-item.received_qty+item.returned_qty>0));
        END IF;
    END IF;
    IF affected THEN RAISE EXCEPTION 'Supply or analysis has active private future transfers; cancel remaining commitments first' USING ERRCODE='23514'; END IF;
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;

CREATE OR REPLACE FUNCTION fn_preplan_future_public_release_qty(p_action UUID,p_external UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(cancel.public_release_qty),0)
    FROM preplan_future_supply_transfer_cancellations cancel
    JOIN preplan_future_supply_transfers transfer ON transfer.id=cancel.transfer_id
    JOIN preplan_supply_action_allocations source ON source.id=transfer.source_allocation_id
    WHERE source.action_id=p_action AND source.external_item_id=p_external
$$;

CREATE OR REPLACE FUNCTION fn_preplan_public_source_private_open_qty(p_action UUID,p_external UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    WITH private_allocation AS (
        SELECT source.id FROM preplan_supply_action_allocations source
        WHERE source.action_id=p_action AND source.external_item_id=p_external
        UNION
        SELECT transfer.target_allocation_id
        FROM preplan_future_supply_transfers transfer
        JOIN preplan_supply_action_allocations source ON source.id=transfer.source_allocation_id
        WHERE source.action_id=p_action AND source.external_item_id=p_external
    )
    SELECT COALESCE(sum(GREATEST(fn_preplan_allocation_admitted_qty(id)
        -fn_preplan_allocation_received_qty(id),0)),0) FROM private_allocation
$$;

DO $released_public_scope$
DECLARE definition TEXT; needle TEXT;
BEGIN
    -- Preserve the legacy declared/runtime combination, then add the separate
    -- audited release. In particular public900 + released40 is 940, not max900.
    SELECT rtrim(pg_get_viewdef('v_preplan_public_supply_sources_v474'::regclass,true),E';\n\r ')
      INTO definition;
    EXECUTE 'CREATE OR REPLACE VIEW v_preplan_public_supply_sources_v474 AS WITH legacy AS ('
      || definition || '), released AS (
        SELECT source.action_id source_action_id,source.external_item_id,
               sum(cancel.public_release_qty)::numeric released_qty
        FROM preplan_future_supply_transfer_cancellations cancel
        JOIN preplan_future_supply_transfers transfer ON transfer.id=cancel.transfer_id
        JOIN preplan_supply_action_allocations source ON source.id=transfer.source_allocation_id
        GROUP BY source.action_id,source.external_item_id
        HAVING sum(cancel.public_release_qty)>0)
        SELECT COALESCE(legacy.source_action_id,released.source_action_id) source_action_id,
               COALESCE(legacy.external_item_id,released.external_item_id) external_item_id,
               (COALESCE(legacy.source_limit_qty,0)+COALESCE(released.released_qty,0))::numeric source_limit_qty
        FROM legacy FULL JOIN released USING(source_action_id,external_item_id)';

    SELECT pg_get_functiondef('fn_preplan_public_source_approved_capacity(uuid,uuid)'::regprocedure) INTO definition;
    needle:='WHEN demand_anchor THEN source_action.requested_qty';
    IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'V571 public source approved baseline changed'; END IF;
    EXECUTE replace(definition,needle,'WHEN demand_anchor THEN GREATEST(source_action.requested_qty
        -fn_preplan_future_public_release_qty(p_action_id,p_external_item_id),0)');

    SELECT pg_get_functiondef('fn_preplan_order_public_source_qty(uuid,uuid,text,uuid)'::regprocedure) INTO definition;
    IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'V571 public order baseline changed'; END IF;
    EXECUTE replace(definition,needle,'WHEN demand_anchor THEN GREATEST(source_action.requested_qty
        -fn_preplan_future_public_release_qty(p_action_id,p_external_item_id),0)');

    SELECT pg_get_functiondef('fn_preplan_public_source_open_qty(uuid,uuid)'::regprocedure) INTO definition;
    needle:='WHEN demand_anchor THEN GREATEST(source_action.requested_qty
            - fn_preplan_action_effective_exact_qty(source_action.id),0)';
    IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'V571 public open private scope changed'; END IF;
    EXECUTE replace(definition,needle,'WHEN demand_anchor THEN fn_preplan_public_source_private_open_qty(p_action_id,p_external_item_id)');

    -- Fulfilled root output is received supply too. It must not re-open a claim
    -- or consume the still-public availability after its exact peg was settled.
    SELECT pg_get_viewdef('v_preplan_public_surplus_source_state'::regclass,true) INTO definition;
    IF strpos(definition,'fn_preplan_action_effective_exact_qty')=0 THEN RAISE EXCEPTION 'V571 public claim view receipt contract changed'; END IF;
    EXECUTE 'CREATE OR REPLACE VIEW v_preplan_public_surplus_source_state AS '
      || replace(definition,'fn_preplan_action_effective_exact_qty','fn_preplan_action_received_qty');
    SELECT pg_get_functiondef('fn_validate_preplan_shared_future_claim()'::regprocedure) INTO definition;
    IF strpos(definition,'fn_preplan_action_effective_exact_qty')=0 THEN RAISE EXCEPTION 'V571 public claim guard receipt contract changed'; END IF;
    EXECUTE replace(definition,'fn_preplan_action_effective_exact_qty','fn_preplan_action_received_qty');
END;
$released_public_scope$;

DO $shared_claim_status_only$
DECLARE definition TEXT; needle TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_validate_preplan_shared_future_claim()'::regprocedure) INTO definition;
    needle:='allocation_item_count INTEGER;';
    IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'V571 shared claim status declaration changed'; END IF;
    definition:=replace(definition,needle,needle || E'\n    validate_open BOOLEAN := TRUE;');
    needle:='IF TG_TABLE_NAME=''preplan_supply_action_allocations'' THEN';
    IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'V571 shared claim status entry changed'; END IF;
    definition:=replace(definition,needle,'IF TG_TABLE_NAME=''preplan_supply_actions'' AND TG_OP=''UPDATE'' THEN
        validate_open := (to_jsonb(NEW)-''status''-''updated_at'')
            IS DISTINCT FROM (to_jsonb(OLD)-''status''-''updated_at'');
    END IF;
    ' || needle);
    needle:='OR other_claim_open+current_claim_open
            > fn_preplan_public_source_open_qty(
                source_action.id,expected_item) THEN';
    IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'V571 shared claim instantaneous open clause changed'; END IF;
    definition:=replace(definition,needle,'OR (validate_open AND other_claim_open+current_claim_open
            > fn_preplan_public_source_open_qty(
                source_action.id,expected_item)) THEN');
    EXECUTE definition;
END;
$shared_claim_status_only$;

CREATE OR REPLACE FUNCTION fn_procurement_order_source_pending_qty(
    p_receipt_type TEXT,p_order_item_id UUID,p_source_item_id UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    WITH item AS (
        SELECT COALESCE(returned_qty,0)*COALESCE(unit_rate,1) returned_base
        FROM purchase_order_items WHERE p_receipt_type='PURCHASE' AND id=p_order_item_id
        UNION ALL
        SELECT COALESCE(returned_qty,0)*COALESCE(unit_rate,1)
        FROM subcontract_order_items WHERE p_receipt_type='SUBCONTRACT' AND id=p_order_item_id
    ), receipt AS (
        SELECT line.id,line.qty*COALESCE(line.unit_rate,1) base_qty
        FROM purchase_receipt_items line JOIN purchase_receipts header ON header.id=line.receipt_id
        WHERE p_receipt_type='PURCHASE' AND line.order_item_id=p_order_item_id
          AND NOT line.is_deleted AND NOT header.is_deleted AND header.status=1
        UNION ALL
        SELECT line.id,line.qty*COALESCE(line.unit_rate,1)
        FROM subcontract_receipt_items line JOIN subcontract_receipts header ON header.id=line.receipt_id
        WHERE p_receipt_type='SUBCONTRACT' AND line.order_item_id=p_order_item_id
          AND NOT line.is_deleted AND NOT header.is_deleted AND header.status=1
    ), progress AS (
        SELECT COALESCE(sum(CASE WHEN inspection.id IS NULL THEN receipt.base_qty
            WHEN inspection.status='REVERSED' THEN 0 ELSE inspection.warehouse_stocked_base_qty END),0) qualified,
          COALESCE(sum(CASE WHEN inspection.id IS NULL OR inspection.status='REVERSED' THEN 0
            ELSE GREATEST(inspection.received_base_qty-inspection.failed_base_qty
                 -inspection.warehouse_stocked_base_qty,0) END),0) pending
        FROM receipt LEFT JOIN procurement_inspection_items inspection
          ON inspection.receipt_type=p_receipt_type AND inspection.receipt_item_id=receipt.id
    )
    SELECT COALESCE((SELECT fn_procurement_source_interval_qty(
        p_receipt_type,p_order_item_id,p_source_item_id,
        GREATEST(progress.qualified-item.returned_base,0),
        GREATEST(progress.qualified-item.returned_base,0)+progress.pending)
        FROM item CROSS JOIN progress),0)
$$;

CREATE OR REPLACE FUNCTION fn_preplan_public_source_open_qty(
    p_action_id UUID,p_external_item_id UUID
) RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE source_action preplan_supply_actions%ROWTYPE;
        open_qty NUMERIC(18,4):=0; private_open NUMERIC(18,4):=0;
BEGIN
    SELECT * INTO source_action FROM preplan_supply_actions WHERE id=p_action_id;
    IF source_action.id IS NULL THEN RETURN 0; END IF;
    IF EXISTS(SELECT 1 FROM preplan_supply_action_allocations
        WHERE action_id=p_action_id AND external_item_id=p_external_item_id) THEN
        private_open:=fn_preplan_public_source_private_open_qty(p_action_id,p_external_item_id);
    ELSIF source_action.safety_external_item_id=p_external_item_id THEN
        private_open:=source_action.safety_replenishment_qty;
    END IF;
    IF source_action.route='BUY' THEN
        SELECT COALESCE(sum(
          CASE WHEN header.is_closed THEN 0 ELSE fn_procurement_order_source_remaining_qty(
              'PURCHASE',item.id,p_external_item_id) END
          +fn_procurement_order_source_pending_qty('PURCHASE',item.id,p_external_item_id)),0)
        INTO open_qty
        FROM purchase_order_item_sources source JOIN purchase_order_items item ON item.id=source.order_item_id
        JOIN purchase_orders header ON header.id=item.order_id
        WHERE source.request_item_id=p_external_item_id AND NOT item.is_deleted
          AND NOT header.is_deleted AND header.status=1;
    ELSIF source_action.route='SUBCONTRACT' THEN
        SELECT COALESCE(sum(
          CASE WHEN header.is_closed THEN 0 ELSE fn_procurement_order_source_remaining_qty(
              'SUBCONTRACT',item.id,p_external_item_id) END
          +fn_procurement_order_source_pending_qty('SUBCONTRACT',item.id,p_external_item_id)),0)
        INTO open_qty
        FROM subcontract_order_item_sources source JOIN subcontract_order_items item ON item.id=source.order_item_id
        JOIN subcontract_orders header ON header.id=item.order_id
        WHERE source.application_item_id=p_external_item_id AND NOT item.is_deleted
          AND NOT header.is_deleted AND header.status=1;
    END IF;
    RETURN LEAST(fn_preplan_public_source_approved_capacity(p_action_id,p_external_item_id),
        GREATEST(open_qty-private_open,0));
END;
$$;

DO $shared_claim_cancel_capacity$
DECLARE definition TEXT; needle TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_validate_preplan_shared_future_claim()'::regprocedure) INTO definition;
    needle:='OR other_claim_total+claim_action.requested_qty';
    IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'V571 shared claim cancel total contract changed'; END IF;
    definition:=replace(definition,needle,'OR other_claim_total+(CASE WHEN claim_action.status=''CANCELLED'' THEN 0 ELSE claim_action.requested_qty END)');
    needle:='OR (validate_open AND other_claim_open+current_claim_open';
    IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'V571 shared claim cancel open contract changed'; END IF;
    definition:=replace(definition,needle,'OR (validate_open AND claim_action.status<>''CANCELLED'' AND other_claim_open+current_claim_open');
    EXECUTE definition;
END;
$shared_claim_cancel_capacity$;

CREATE OR REPLACE FUNCTION fn_preplan_external_expected_qty(p_action UUID,p_external UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(source.remaining_qty+source.pending_qty),0)
    FROM preplan_supply_actions action CROSS JOIN LATERAL (
      SELECT CASE WHEN header.is_closed THEN 0 ELSE fn_procurement_order_source_remaining_qty('PURCHASE',item.id,p_external) END remaining_qty,
             fn_procurement_order_source_pending_qty('PURCHASE',item.id,p_external) pending_qty
      FROM purchase_order_item_sources link JOIN purchase_order_items item ON item.id=link.order_item_id AND NOT item.is_deleted
      JOIN purchase_orders header ON header.id=item.order_id AND header.status=1 AND NOT header.is_deleted
      WHERE action.route='BUY' AND link.request_item_id=p_external
      UNION ALL
      SELECT CASE WHEN header.is_closed THEN 0 ELSE fn_procurement_order_source_remaining_qty('SUBCONTRACT',item.id,p_external) END,
             fn_procurement_order_source_pending_qty('SUBCONTRACT',item.id,p_external)
      FROM subcontract_order_item_sources link JOIN subcontract_order_items item ON item.id=link.order_item_id AND NOT item.is_deleted
      JOIN subcontract_orders header ON header.id=item.order_id AND header.status=1 AND NOT header.is_deleted
      WHERE action.route='SUBCONTRACT' AND link.application_item_id=p_external
    ) source WHERE action.id=p_action
$$;

CREATE OR REPLACE FUNCTION fn_preplan_future_source_available_qty(p_allocation UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT LEAST(fn_preplan_future_source_private_capacity_qty(allocation.id),
      GREATEST(fn_preplan_external_expected_qty(allocation.action_id,allocation.external_item_id)
        -COALESCE((SELECT sum(GREATEST(fn_preplan_allocation_admitted_qty(transfer.target_allocation_id)
            -fn_preplan_allocation_received_qty(transfer.target_allocation_id),0))
          FROM preplan_future_supply_transfers transfer WHERE transfer.external_item_id=allocation.external_item_id),0)
        -COALESCE((SELECT sum(GREATEST(fn_preplan_allocation_admitted_qty(prior.id)-fn_preplan_allocation_received_qty(prior.id),0))
          FROM preplan_supply_action_allocations prior JOIN preplan_supply_actions action ON action.id=prior.action_id
          WHERE prior.external_item_id=allocation.external_item_id AND action.operation_type='SUPPLY' AND action.status<>'CANCELLED'
            AND (prior.created_at,prior.id)<(allocation.created_at,allocation.id)),0),0))
      FROM preplan_supply_action_allocations allocation WHERE allocation.id=p_allocation),0)
$$;

CREATE OR REPLACE FUNCTION fn_preplan_future_allocation_pending_qty(p_allocation UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT CASE WHEN transfer.id IS NULL
        THEN fn_preplan_future_source_available_qty(allocation.id)
        ELSE LEAST(GREATEST(fn_preplan_allocation_admitted_qty(allocation.id)-fn_preplan_allocation_received_qty(allocation.id),0),
          GREATEST(fn_preplan_external_expected_qty(source.action_id,transfer.external_item_id)
            -COALESCE((SELECT sum(GREATEST(fn_preplan_allocation_admitted_qty(prior.target_allocation_id)
                -fn_preplan_allocation_received_qty(prior.target_allocation_id),0))
              FROM preplan_future_supply_transfers prior WHERE prior.external_item_id=transfer.external_item_id
                AND (prior.created_at,prior.id)<(transfer.created_at,transfer.id)),0),0)) END
      FROM preplan_supply_action_allocations allocation
      LEFT JOIN preplan_future_supply_transfers transfer ON transfer.target_allocation_id=allocation.id
      LEFT JOIN preplan_supply_action_allocations source ON source.id=transfer.source_allocation_id
      WHERE allocation.id=p_allocation),0)
$$;

CREATE OR REPLACE FUNCTION fn_preplan_future_action_pending_qty(p_action UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(fn_preplan_future_allocation_pending_qty(id)),0)
    FROM preplan_supply_action_allocations WHERE action_id=p_action
$$;

CREATE OR REPLACE VIEW v_preplan_public_surplus_source_state AS
WITH source AS (
    SELECT action.*,public.external_item_id AS claim_external_item_id,
           fn_preplan_public_source_approved_capacity(
               action.id,public.external_item_id) AS approved_capacity_qty,
           fn_preplan_public_source_open_qty(
               action.id,public.external_item_id) AS approved_open_qty
    FROM preplan_supply_actions action
    JOIN v_preplan_public_supply_sources_v474 public
      ON public.source_action_id=action.id
    WHERE action.operation_type='SUPPLY'
      AND action.route IN ('BUY','SUBCONTRACT')
      AND action.status <> 'CANCELLED'
), claim_action AS (
    SELECT claim.id,claim.claim_source_action_id AS source_action_id,
           claim.requested_qty,
           min(allocation.external_item_id::text)::uuid AS external_item_id,
           count(DISTINCT allocation.external_item_id) AS item_count
    FROM preplan_supply_actions claim
    JOIN preplan_supply_action_allocations allocation
      ON allocation.action_id=claim.id
    WHERE claim.operation_type='SHARED_FUTURE_CLAIM'
      AND claim.status <> 'CANCELLED'
    GROUP BY claim.id,claim.claim_source_action_id,claim.requested_qty
), claim AS (
    SELECT source_action_id,external_item_id,
           SUM(requested_qty)::numeric AS claimed_qty,
           SUM(GREATEST(requested_qty
               -fn_preplan_action_received_qty(id),0))::numeric
               AS claim_open_qty
    FROM claim_action WHERE item_count=1
    GROUP BY source_action_id,external_item_id
), eta AS (
    SELECT source.id AS source_action_id,source.claim_external_item_id,
           min(candidate.eta) AS expected_date
    FROM source
    LEFT JOIN LATERAL (
        SELECT COALESCE(item.deliver_date,header.deliver_date) AS eta
        FROM purchase_order_item_sources link
        JOIN purchase_order_items item ON item.id=link.order_item_id
        JOIN purchase_orders header ON header.id=item.order_id
        WHERE source.route='BUY'
          AND link.request_item_id=source.claim_external_item_id
          AND header.status=1 AND header.is_deleted=FALSE
          AND item.is_deleted=FALSE
          AND ((NOT header.is_closed AND fn_procurement_order_source_remaining_qty('PURCHASE',item.id,link.request_item_id)>0)
               OR fn_procurement_order_source_pending_qty('PURCHASE',item.id,link.request_item_id)>0)
        UNION ALL
        SELECT COALESCE(item.deliver_date,header.deliver_date)
        FROM subcontract_order_item_sources link
        JOIN subcontract_order_items item ON item.id=link.order_item_id
        JOIN subcontract_orders header ON header.id=item.order_id
        WHERE source.route='SUBCONTRACT'
          AND link.application_item_id=source.claim_external_item_id
          AND header.status=1 AND header.is_deleted=FALSE
          AND item.is_deleted=FALSE
          AND ((NOT header.is_closed AND fn_procurement_order_source_remaining_qty('SUBCONTRACT',item.id,link.application_item_id)>0)
               OR fn_procurement_order_source_pending_qty('SUBCONTRACT',item.id,link.application_item_id)>0)
    ) candidate ON TRUE
    GROUP BY source.id,source.claim_external_item_id
)
SELECT source.id AS source_action_id,
       source.analysis_id AS source_analysis_id,
       source.warehouse_id,source.goods_id,source.color_id,source.unit_id,
       source.route,source.external_document_type,
       source.external_document_id,source.external_document_no,
       source.claim_external_item_id,
       source.approved_capacity_qty,source.approved_open_qty,
       COALESCE(claim.claimed_qty,0)::numeric AS claimed_qty,
       COALESCE(claim.claim_open_qty,0)::numeric AS claim_open_qty,
       LEAST(
           GREATEST(source.approved_capacity_qty
               -COALESCE(claim.claimed_qty,0),0),
           GREATEST(source.approved_open_qty
               -COALESCE(claim.claim_open_qty,0),0))::numeric
           AS available_to_claim_qty,
       eta.expected_date,source.created_at
FROM source
LEFT JOIN claim
  ON claim.source_action_id=source.id
 AND claim.external_item_id=source.claim_external_item_id
LEFT JOIN eta
  ON eta.source_action_id=source.id
 AND eta.claim_external_item_id=source.claim_external_item_id;

CREATE OR REPLACE FUNCTION fn_preplan_action_has_shared_claims(p_action UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM preplan_supply_actions claim
        WHERE claim.claim_source_action_id=p_action
          AND claim.operation_type='SHARED_FUTURE_CLAIM' AND claim.status<>'CANCELLED')
$$;

CREATE OR REPLACE FUNCTION fn_preplan_action_has_shared_claim_history(p_action UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM preplan_supply_actions claim
        WHERE claim.claim_source_action_id=p_action AND claim.operation_type='SHARED_FUTURE_CLAIM')
$$;

CREATE OR REPLACE FUNCTION fn_preplan_shared_action_pending_qty(p_action UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT LEAST(
        GREATEST(fn_preplan_action_admitted_qty(claim.id)-fn_preplan_action_received_qty(claim.id),0),
        GREATEST(fn_preplan_public_source_open_qty(claim.claim_source_action_id,source.external_item_id)
          -COALESCE((SELECT sum(GREATEST(fn_preplan_action_admitted_qty(prior.id)-fn_preplan_action_received_qty(prior.id),0))
            FROM preplan_supply_actions prior
            WHERE prior.operation_type='SHARED_FUTURE_CLAIM' AND prior.status<>'CANCELLED'
              AND prior.claim_source_action_id=claim.claim_source_action_id
              AND (prior.created_at,prior.id)<(claim.created_at,claim.id)
              AND EXISTS(SELECT 1 FROM preplan_supply_action_allocations allocation
                  WHERE allocation.action_id=prior.id AND allocation.external_item_id=source.external_item_id)),0),0))
      FROM preplan_supply_actions claim
      CROSS JOIN LATERAL(SELECT min(external_item_id::text)::uuid external_item_id,
          count(DISTINCT external_item_id) item_count
        FROM preplan_supply_action_allocations WHERE action_id=claim.id) source
      WHERE claim.id=p_action AND claim.operation_type='SHARED_FUTURE_CLAIM'
        AND claim.status<>'CANCELLED' AND source.item_count=1),0)
$$;

DO $shared_cancelled_source_history$
DECLARE definition TEXT; needle TEXT:='OR source_action.status=''CANCELLED''';
BEGIN
    SELECT pg_get_functiondef('fn_validate_preplan_shared_future_claim()'::regprocedure) INTO definition;
    IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'V571 shared cancelled source identity contract changed'; END IF;
    EXECUTE replace(definition,needle,'OR (source_action.status=''CANCELLED'' AND claim_action.status<>''CANCELLED'')');
END;
$shared_cancelled_source_history$;

CREATE OR REPLACE FUNCTION fn_preplan_shared_allocation_pending_qty(p_allocation UUID)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT LEAST(
        GREATEST(allocation.allocated_qty-fn_preplan_allocation_received_qty(allocation.id),0),
        GREATEST(fn_preplan_shared_action_pending_qty(allocation.action_id)
          -COALESCE((SELECT sum(GREATEST(prior.allocated_qty-fn_preplan_allocation_received_qty(prior.id),0))
            FROM preplan_supply_action_allocations prior WHERE prior.action_id=allocation.action_id
              AND (prior.created_at,prior.id)<(allocation.created_at,allocation.id)),0),0))
      FROM preplan_supply_action_allocations allocation WHERE allocation.id=p_allocation),0)
$$;

DROP TRIGGER trg_future_transfer_purchase_item ON purchase_order_items;
CREATE TRIGGER trg_future_transfer_purchase_item BEFORE UPDATE OF qty,unit_rate,goods_id,color_id,unit_id,order_id,is_deleted OR DELETE ON purchase_order_items FOR EACH ROW EXECUTE FUNCTION fn_guard_future_transfer_source_lifecycle();
ALTER TABLE purchase_order_items ENABLE ALWAYS TRIGGER trg_future_transfer_purchase_item;
DROP TRIGGER trg_future_transfer_subcontract_item ON subcontract_order_items;
CREATE TRIGGER trg_future_transfer_subcontract_item BEFORE UPDATE OF qty,unit_rate,goods_id,color_id,unit_id,order_id,is_deleted OR DELETE ON subcontract_order_items FOR EACH ROW EXECUTE FUNCTION fn_guard_future_transfer_source_lifecycle();
ALTER TABLE subcontract_order_items ENABLE ALWAYS TRIGGER trg_future_transfer_subcontract_item;
DROP TRIGGER trg_future_transfer_purchase_sources ON purchase_order_item_sources;
CREATE TRIGGER trg_future_transfer_purchase_sources BEFORE INSERT OR UPDATE OR DELETE ON purchase_order_item_sources FOR EACH ROW EXECUTE FUNCTION fn_guard_future_transfer_source_lifecycle();
ALTER TABLE purchase_order_item_sources ENABLE ALWAYS TRIGGER trg_future_transfer_purchase_sources;
DROP TRIGGER trg_future_transfer_subcontract_sources ON subcontract_order_item_sources;
CREATE TRIGGER trg_future_transfer_subcontract_sources BEFORE INSERT OR UPDATE OR DELETE ON subcontract_order_item_sources FOR EACH ROW EXECUTE FUNCTION fn_guard_future_transfer_source_lifecycle();
ALTER TABLE subcontract_order_item_sources ENABLE ALWAYS TRIGGER trg_future_transfer_subcontract_sources;
