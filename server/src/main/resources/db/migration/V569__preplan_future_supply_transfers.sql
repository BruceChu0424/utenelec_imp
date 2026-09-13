-- Reassign approved, not-yet-qualified external demand supply. Original
-- commercial and allocation quantities remain immutable; no stock is moved.
CREATE TABLE preplan_future_supply_transfers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_allocation_id UUID NOT NULL REFERENCES preplan_supply_action_allocations(id),
    source_analysis_id UUID NOT NULL,
    source_material_id UUID NOT NULL,
    target_analysis_id UUID NOT NULL,
    target_material_id UUID NOT NULL,
    target_action_id UUID NOT NULL UNIQUE REFERENCES preplan_supply_actions(id) DEFERRABLE INITIALLY DEFERRED,
    target_allocation_id UUID NOT NULL UNIQUE REFERENCES preplan_supply_action_allocations(id) DEFERRABLE INITIALLY DEFERRED,
    external_item_id UUID NOT NULL,
    qty NUMERIC(18,4) NOT NULL CHECK(qty>0),
    source_version BIGINT NOT NULL,
    source_fingerprint TEXT NOT NULL,
    target_version BIGINT NOT NULL,
    target_fingerprint TEXT NOT NULL,
    expected_date DATE,
    target_need_date DATE,
    allow_late_supply BOOLEAN NOT NULL DEFAULT FALSE,
    reason TEXT NOT NULL CHECK(length(btrim(reason)) BETWEEN 2 AND 1000),
    idempotency_key TEXT NOT NULL,
    request_hash TEXT NOT NULL CHECK(request_hash ~ '^[a-f0-9]{64}$'),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(created_by,idempotency_key),
    FOREIGN KEY(source_analysis_id,source_material_id) REFERENCES production_material_analysis_materials(analysis_id,id),
    FOREIGN KEY(target_analysis_id,target_material_id) REFERENCES production_material_analysis_materials(analysis_id,id),
    CHECK(source_analysis_id<>target_analysis_id)
);
CREATE INDEX idx_future_transfer_source ON preplan_future_supply_transfers(source_allocation_id,created_at,id);
CREATE INDEX idx_future_transfer_target ON preplan_future_supply_transfers(target_analysis_id,target_material_id,created_at,id);

CREATE TABLE preplan_future_supply_transfer_cancellations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transfer_id UUID NOT NULL REFERENCES preplan_future_supply_transfers(id),
    qty NUMERIC(18,4) NOT NULL CHECK(qty>0),
    reason TEXT NOT NULL CHECK(length(btrim(reason)) BETWEEN 2 AND 1000),
    idempotency_key TEXT NOT NULL,
    request_hash TEXT NOT NULL CHECK(request_hash ~ '^[a-f0-9]{64}$'),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(created_by,idempotency_key)
);
CREATE INDEX idx_future_transfer_cancel_source ON preplan_future_supply_transfer_cancellations(transfer_id,id);

ALTER TABLE preplan_supply_actions DROP CONSTRAINT preplan_supply_action_operation_type_chk,
    DROP CONSTRAINT preplan_supply_action_operation_shape_chk;
ALTER TABLE preplan_supply_actions ADD CONSTRAINT preplan_supply_action_operation_type_chk
    CHECK(operation_type IN('SUPPLY','SHARED_FUTURE_CLAIM','FUTURE_TRANSFER')),
    ADD CONSTRAINT preplan_supply_action_operation_shape_chk CHECK(
      (operation_type='SUPPLY' AND claim_source_action_id IS NULL)
      OR (operation_type IN('SHARED_FUTURE_CLAIM','FUTURE_TRANSFER') AND claim_source_action_id IS NOT NULL
        AND requested_qty>0 AND public_surplus_qty=0 AND public_surplus_external_item_id IS NULL
        AND safety_replenishment_qty=0 AND route IN('BUY','SUBCONTRACT')));

CREATE FUNCTION fn_preplan_future_transfer_cancelled_qty(p_transfer UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(qty),0) FROM preplan_future_supply_transfer_cancellations WHERE transfer_id=p_transfer
$$;
CREATE FUNCTION fn_preplan_allocation_received_qty(p_allocation UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT fn_preplan_allocation_effective_exact_qty(p_allocation)+COALESCE((
      SELECT sum(CASE WHEN output.event_kind='FULFILL' THEN output.qty_base ELSE -output.qty_base END)
      FROM preplan_root_output_events output JOIN preplan_analysis_stock_exact_pegs exact ON exact.stock_reservation_id=output.source_reservation_id
      WHERE exact.supply_action_allocation_id=p_allocation),0)
$$;
CREATE FUNCTION fn_preplan_action_received_qty(p_action UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(fn_preplan_allocation_received_qty(id)),0) FROM preplan_supply_action_allocations WHERE action_id=p_action
$$;
CREATE FUNCTION fn_preplan_future_transfer_received_qty(p_transfer UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT fn_preplan_allocation_received_qty(target_allocation_id)
      FROM preplan_future_supply_transfers WHERE id=p_transfer),0)
$$;
CREATE FUNCTION fn_preplan_allocation_admitted_qty(p_allocation UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT GREATEST(allocation.allocated_qty
      -COALESCE((SELECT sum(transfer.qty-fn_preplan_future_transfer_cancelled_qty(transfer.id))
          FROM preplan_future_supply_transfers transfer WHERE transfer.source_allocation_id=allocation.id),0)
      -COALESCE((SELECT fn_preplan_future_transfer_cancelled_qty(transfer.id)
          FROM preplan_future_supply_transfers transfer WHERE transfer.target_allocation_id=allocation.id),0),0)
      FROM preplan_supply_action_allocations allocation WHERE allocation.id=p_allocation),0)
$$;
CREATE FUNCTION fn_preplan_action_admitted_qty(p_action UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT sum(fn_preplan_allocation_admitted_qty(id)) FROM preplan_supply_action_allocations
        WHERE action_id=p_action),(SELECT requested_qty FROM preplan_supply_actions WHERE id=p_action),0)
$$;
CREATE FUNCTION fn_preplan_action_has_future_transfer(p_action UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM preplan_future_supply_transfers transfer
      JOIN preplan_supply_action_allocations source ON source.id=transfer.source_allocation_id
      WHERE transfer.target_action_id=p_action OR source.action_id=p_action
        AND transfer.qty>fn_preplan_future_transfer_cancelled_qty(transfer.id))
$$;

-- Both private beneficiaries consume the original exact-order budget. Public
-- claims remain in their own operation bucket and never lose the public 900.
DO $exact_bucket$
DECLARE definition TEXT; needle TEXT:='action.operation_type=p_operation_type';
BEGIN
    SELECT pg_get_functiondef('fn_preplan_order_exact_attributed_qty(text,uuid,uuid,text)'::regprocedure) INTO definition;
    IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'V569 exact-order operation contract changed'; END IF;
    EXECUTE replace(definition,needle,'(action.operation_type=p_operation_type OR p_operation_type=''SUPPLY'' AND action.operation_type=''FUTURE_TRANSFER'')');
    SELECT pg_get_functiondef('fn_check_preplan_analysis_stock_exact_peg()'::regprocedure) INTO definition;
    needle:='> allocation.allocated_qty';
    IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'V569 exact allocation capacity contract changed'; END IF;
    EXECUTE replace(definition,needle,'> (CASE WHEN allocation.id IS NULL THEN NULL ELSE fn_preplan_allocation_admitted_qty(allocation.id) END)');
END;
$exact_bucket$;

CREATE FUNCTION fn_preplan_external_exact_approved_qty(p_action UUID,p_external UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
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
CREATE FUNCTION fn_preplan_future_source_available_qty(p_allocation UUID) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT GREATEST(LEAST(allocation.allocated_qty,
      GREATEST(fn_preplan_external_exact_approved_qty(action.id,allocation.external_item_id)-COALESCE((
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

CREATE VIEW v_preplan_future_supply_transfer_state AS
SELECT transfer.*,fn_preplan_future_transfer_cancelled_qty(transfer.id)::numeric cancelled_qty,
       fn_preplan_future_transfer_received_qty(transfer.id)::numeric received_qty,
       GREATEST(transfer.qty-fn_preplan_future_transfer_cancelled_qty(transfer.id)-fn_preplan_future_transfer_received_qty(transfer.id),0)::numeric remaining_qty,
       CASE WHEN fn_preplan_future_transfer_cancelled_qty(transfer.id)=transfer.qty THEN 'CANCELLED'
            WHEN fn_preplan_future_transfer_received_qty(transfer.id)+fn_preplan_future_transfer_cancelled_qty(transfer.id)>=transfer.qty THEN 'RECEIVED'
            WHEN fn_preplan_future_transfer_received_qty(transfer.id)>0 THEN 'PARTIAL' ELSE 'WAITING_RECEIPT' END status
FROM preplan_future_supply_transfers transfer;

CREATE FUNCTION fn_guard_preplan_future_transfer() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source preplan_supply_action_allocations%ROWTYPE; source_action preplan_supply_actions%ROWTYPE;
        target production_material_analysis_materials%ROWTYPE; source_material production_material_analysis_materials%ROWTYPE;
        cancelled NUMERIC; received NUMERIC; transfer preplan_future_supply_transfers%ROWTYPE;
BEGIN
    IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Future supply transfer history is append-only' USING ERRCODE='55000'; END IF;
    IF TG_TABLE_NAME='preplan_future_supply_transfer_cancellations' THEN
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
CREATE TRIGGER trg_future_transfer_history BEFORE INSERT OR UPDATE OR DELETE ON preplan_future_supply_transfers
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_future_transfer();
CREATE TRIGGER trg_future_transfer_cancel_history BEFORE INSERT OR UPDATE OR DELETE ON preplan_future_supply_transfer_cancellations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_future_transfer();
ALTER TABLE preplan_future_supply_transfers ENABLE ALWAYS TRIGGER trg_future_transfer_history;
ALTER TABLE preplan_future_supply_transfer_cancellations ENABLE ALWAYS TRIGGER trg_future_transfer_cancel_history;

CREATE FUNCTION fn_assert_preplan_future_transfer() RETURNS trigger LANGUAGE plpgsql AS $$
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
CREATE CONSTRAINT TRIGGER trg_assert_future_transfer AFTER INSERT ON preplan_future_supply_transfers
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_preplan_future_transfer();
CREATE CONSTRAINT TRIGGER trg_assert_future_transfer_cancel AFTER INSERT ON preplan_future_supply_transfer_cancellations
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_preplan_future_transfer();
ALTER TABLE preplan_future_supply_transfers ENABLE ALWAYS TRIGGER trg_assert_future_transfer;
ALTER TABLE preplan_future_supply_transfer_cancellations ENABLE ALWAYS TRIGGER trg_assert_future_transfer_cancel;
CREATE TRIGGER trg_audit_preplan_future_supply_transfers AFTER INSERT OR UPDATE OR DELETE ON preplan_future_supply_transfers FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_preplan_future_supply_transfer_cancellations AFTER INSERT OR UPDATE OR DELETE ON preplan_future_supply_transfer_cancellations FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE FUNCTION fn_guard_future_transfer_action() RETURNS trigger LANGUAGE plpgsql AS $$
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
CREATE TRIGGER trg_guard_future_transfer_action BEFORE INSERT OR UPDATE ON preplan_supply_actions
    FOR EACH ROW EXECUTE FUNCTION fn_guard_future_transfer_action();
ALTER TABLE preplan_supply_actions ENABLE ALWAYS TRIGGER trg_guard_future_transfer_action;

CREATE FUNCTION fn_future_external_has_transfers(p_external UUID) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM preplan_future_supply_transfers transfer
      WHERE transfer.external_item_id=p_external AND transfer.qty>fn_preplan_future_transfer_cancelled_qty(transfer.id))
$$;
CREATE FUNCTION fn_guard_future_transfer_source_lifecycle() RETURNS trigger LANGUAGE plpgsql AS $$
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
        external:=CASE WHEN TG_TABLE_NAME='purchase_order_item_sources' THEN (to_jsonb(OLD)->>'request_item_id')::uuid ELSE (to_jsonb(OLD)->>'application_item_id')::uuid END;
        affected:=fn_future_external_has_transfers(external);
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
CREATE TRIGGER trg_future_transfer_purchase_item BEFORE UPDATE OF qty,unit_rate,goods_id,color_id,unit_id,order_id,is_deleted ON purchase_order_items FOR EACH ROW EXECUTE FUNCTION fn_guard_future_transfer_source_lifecycle();
CREATE TRIGGER trg_future_transfer_subcontract_item BEFORE UPDATE OF qty,unit_rate,goods_id,color_id,unit_id,order_id,is_deleted ON subcontract_order_items FOR EACH ROW EXECUTE FUNCTION fn_guard_future_transfer_source_lifecycle();
CREATE TRIGGER trg_future_transfer_purchase_sources BEFORE UPDATE OR DELETE ON purchase_order_item_sources FOR EACH ROW EXECUTE FUNCTION fn_guard_future_transfer_source_lifecycle();
CREATE TRIGGER trg_future_transfer_subcontract_sources BEFORE UPDATE OR DELETE ON subcontract_order_item_sources FOR EACH ROW EXECUTE FUNCTION fn_guard_future_transfer_source_lifecycle();
CREATE TRIGGER trg_future_transfer_purchase_header BEFORE UPDATE OF status,is_deleted,is_closed ON purchase_orders FOR EACH ROW EXECUTE FUNCTION fn_guard_future_transfer_source_lifecycle();
CREATE TRIGGER trg_future_transfer_subcontract_header BEFORE UPDATE OF status,is_deleted,is_closed ON subcontract_orders FOR EACH ROW EXECUTE FUNCTION fn_guard_future_transfer_source_lifecycle();
CREATE TRIGGER trg_future_transfer_purchase_request BEFORE UPDATE OF status,is_deleted,is_stopped ON purchase_requests FOR EACH ROW EXECUTE FUNCTION fn_guard_future_transfer_source_lifecycle();
CREATE TRIGGER trg_future_transfer_subcontract_application BEFORE UPDATE OF status,is_deleted ON subcontract_applications FOR EACH ROW EXECUTE FUNCTION fn_guard_future_transfer_source_lifecycle();
CREATE TRIGGER trg_future_transfer_analysis BEFORE UPDATE OF status,is_deleted ON production_material_analyses FOR EACH ROW EXECUTE FUNCTION fn_guard_future_transfer_source_lifecycle();
ALTER TABLE purchase_order_items ENABLE ALWAYS TRIGGER trg_future_transfer_purchase_item;
ALTER TABLE subcontract_order_items ENABLE ALWAYS TRIGGER trg_future_transfer_subcontract_item;
ALTER TABLE purchase_order_item_sources ENABLE ALWAYS TRIGGER trg_future_transfer_purchase_sources;
ALTER TABLE subcontract_order_item_sources ENABLE ALWAYS TRIGGER trg_future_transfer_subcontract_sources;
ALTER TABLE purchase_orders ENABLE ALWAYS TRIGGER trg_future_transfer_purchase_header;
ALTER TABLE subcontract_orders ENABLE ALWAYS TRIGGER trg_future_transfer_subcontract_header;
ALTER TABLE purchase_requests ENABLE ALWAYS TRIGGER trg_future_transfer_purchase_request;
ALTER TABLE subcontract_applications ENABLE ALWAYS TRIGGER trg_future_transfer_subcontract_application;
ALTER TABLE production_material_analyses ENABLE ALWAYS TRIGGER trg_future_transfer_analysis;

-- Logical planning warehouses may be sibling leaves of one main warehouse;
-- neither public nor private future promises rewrite any physical stock UUID.
DO $shared_main_scope$
DECLARE definition TEXT;needle TEXT:='source_action.warehouse_id <> claim_action.warehouse_id';
BEGIN
    SELECT pg_get_functiondef('fn_validate_preplan_shared_future_claim()'::regprocedure) INTO definition;
    IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'V569 shared-future warehouse contract changed'; END IF;
    EXECUTE replace(definition,needle,'NOT fn_warehouse_same_main(source_action.warehouse_id,claim_action.warehouse_id)');
END;
$shared_main_scope$;

DO $reset_policy$
DECLARE definition TEXT;needle TEXT:='(''preplan_material_reallocations'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 THEN RAISE EXCEPTION 'V569 reset policy anchor changed'; END IF;
    EXECUTE replace(definition,needle,needle||E',\n    (''preplan_future_supply_transfers'', ''CLEAR''),\n    (''preplan_future_supply_transfer_cancellations'', ''CLEAR'')');
END;
$reset_policy$;
