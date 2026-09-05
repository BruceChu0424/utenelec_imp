-- V474: runtime direct-overorder public supply and warehouse-safe inbound
-- attribution. V465/V472 remain byte-for-byte immutable.

CREATE TABLE preplan_public_supply_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_action_id UUID NOT NULL
        REFERENCES preplan_supply_actions(id) ON DELETE RESTRICT,
    source_external_item_id UUID NOT NULL,
    trigger_order_type TEXT NOT NULL,
    trigger_order_id UUID NOT NULL,
    event_type TEXT NOT NULL,
    qty NUMERIC(18,4) NOT NULL,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE RESTRICT,
    goods_id UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    color_id UUID REFERENCES colors(id) ON DELETE RESTRICT,
    unit_id UUID NOT NULL REFERENCES units(id) ON DELETE RESTRICT,
    route TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT preplan_public_supply_event_order_type_chk
        CHECK (trigger_order_type IN ('PURCHASE','SUBCONTRACT')),
    CONSTRAINT preplan_public_supply_event_type_chk
        CHECK (event_type IN ('GRANT','REVERSE')),
    CONSTRAINT preplan_public_supply_event_qty_chk CHECK (qty > 0),
    CONSTRAINT preplan_public_supply_event_route_chk CHECK (
        (trigger_order_type='PURCHASE' AND route='BUY') OR
        (trigger_order_type='SUBCONTRACT' AND route='SUBCONTRACT')),
    CONSTRAINT preplan_public_supply_event_key_chk CHECK (
        idempotency_key=btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 200),
    CONSTRAINT preplan_public_supply_event_key_uk UNIQUE (idempotency_key)
);

CREATE INDEX idx_preplan_public_supply_event_source
    ON preplan_public_supply_events(
        source_action_id,source_external_item_id,created_at,id);
CREATE INDEX idx_preplan_public_supply_event_order
    ON preplan_public_supply_events(
        trigger_order_type,trigger_order_id,created_at,id);

CREATE VIEW v_preplan_public_supply_event_balance AS
SELECT source_action_id,source_external_item_id,
       SUM(CASE event_type WHEN 'GRANT' THEN qty ELSE -qty END)::numeric
           AS effective_qty
FROM preplan_public_supply_events
GROUP BY source_action_id,source_external_item_id
HAVING SUM(CASE event_type WHEN 'GRANT' THEN qty ELSE -qty END) <> 0;

CREATE OR REPLACE FUNCTION fn_preplan_runtime_public_supply_balance(
    p_action_id UUID,p_external_item_id UUID
) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(CASE event_type
        WHEN 'GRANT' THEN qty ELSE -qty END),0)
    FROM preplan_public_supply_events
    WHERE source_action_id=p_action_id
      AND source_external_item_id=p_external_item_id;
$$;

CREATE OR REPLACE FUNCTION fn_guard_preplan_public_supply_event_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'preplan public supply events are append-only'
        USING ERRCODE='55000';
END;
$$;
CREATE TRIGGER trg_guard_preplan_public_supply_event_mutation
    BEFORE UPDATE OR DELETE ON preplan_public_supply_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_public_supply_event_mutation();
CREATE TRIGGER trg_audit_preplan_public_supply_events
    AFTER INSERT OR UPDATE OR DELETE ON preplan_public_supply_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- The capacity helper covers all three upstream anchors. The declared
-- demand/public/safety quantity is the non-overorder baseline. Safety itself is
-- never claimable; only finance-approved quantity above its baseline is public.
CREATE OR REPLACE FUNCTION fn_preplan_direct_overorder_capacity(
    p_action_id UUID,p_external_item_id UUID
) RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE
    source_action preplan_supply_actions%ROWTYPE;
    owner_count INTEGER;
    baseline_qty NUMERIC(18,4);
    approved_qty NUMERIC(18,4) := 0;
    demand_anchor BOOLEAN;
BEGIN
    SELECT * INTO source_action FROM preplan_supply_actions
    WHERE id=p_action_id;
    SELECT EXISTS(
        SELECT 1 FROM preplan_supply_action_allocations allocation
        WHERE allocation.action_id=p_action_id
          AND allocation.external_item_id=p_external_item_id)
    INTO demand_anchor;
    baseline_qty := CASE
        WHEN demand_anchor THEN source_action.requested_qty
        WHEN source_action.public_surplus_external_item_id=p_external_item_id
            THEN source_action.public_surplus_qty
        WHEN source_action.safety_external_item_id=p_external_item_id
            THEN source_action.safety_replenishment_qty
        ELSE NULL END;
    IF source_action.id IS NULL OR baseline_qty IS NULL
       OR source_action.operation_type <> 'SUPPLY'
       OR source_action.status='CANCELLED'
       OR source_action.route NOT IN ('BUY','SUBCONTRACT')
       OR (source_action.route='SUBCONTRACT' AND EXISTS (
           SELECT 1 FROM goods_bom_items bom
           WHERE bom.goods_id=source_action.goods_id
             AND bom.is_deleted=FALSE)) THEN
        RETURN 0;
    END IF;
    SELECT COUNT(DISTINCT action.id) INTO owner_count
    FROM preplan_supply_actions action
    LEFT JOIN preplan_supply_action_allocations allocation
      ON allocation.action_id=action.id
     AND allocation.external_item_id=p_external_item_id
    WHERE action.operation_type='SUPPLY'
      AND action.status <> 'CANCELLED'
      AND (allocation.id IS NOT NULL
           OR action.public_surplus_external_item_id=p_external_item_id
           OR action.safety_external_item_id=p_external_item_id);
    IF owner_count <> 1 THEN RETURN 0; END IF;
    IF source_action.route='BUY' THEN
        SELECT COALESCE(SUM(fn_purchase_order_source_share(
                   item.id,source.request_item_id,
                   item.qty*COALESCE(item.unit_rate,1))),0)
        INTO approved_qty
        FROM purchase_order_item_sources source
        JOIN purchase_order_items item ON item.id=source.order_item_id
        JOIN purchase_orders header ON header.id=item.order_id
        WHERE source.request_item_id=p_external_item_id
          AND header.status=1 AND header.is_deleted=FALSE
          AND item.is_deleted=FALSE;
    ELSE
        SELECT COALESCE(SUM(fn_subcontract_order_source_share(
                   item.id,source.application_item_id,
                   item.qty*COALESCE(item.unit_rate,1))),0)
        INTO approved_qty
        FROM subcontract_order_item_sources source
        JOIN subcontract_order_items item ON item.id=source.order_item_id
        JOIN subcontract_orders header ON header.id=item.order_id
        WHERE source.application_item_id=p_external_item_id
          AND header.status=1 AND header.is_deleted=FALSE
          AND item.is_deleted=FALSE;
    END IF;
    RETURN GREATEST(approved_qty-baseline_qty,0);
END;
$$;

CREATE VIEW v_preplan_public_supply_sources_v474 AS
WITH source_row AS (
    SELECT action.id AS source_action_id,
           action.public_surplus_external_item_id AS external_item_id,
           action.public_surplus_qty AS declared_qty,
           0::numeric AS runtime_qty,
           EXISTS(
               SELECT 1 FROM preplan_supply_action_allocations allocation
               WHERE allocation.action_id=action.id
                 AND allocation.external_item_id=
                     action.public_surplus_external_item_id)
               AS declared_is_demand_anchor
    FROM preplan_supply_actions action
    WHERE action.operation_type='SUPPLY' AND action.status <> 'CANCELLED'
      AND action.public_surplus_qty > 0
      AND action.public_surplus_external_item_id IS NOT NULL
    UNION ALL
    SELECT balance.source_action_id,balance.source_external_item_id,
           0::numeric,balance.effective_qty,
           EXISTS(
               SELECT 1 FROM preplan_supply_action_allocations allocation
               WHERE allocation.action_id=balance.source_action_id
                 AND allocation.external_item_id=balance.source_external_item_id)
    FROM v_preplan_public_supply_event_balance balance
    WHERE balance.effective_qty > 0
)
SELECT source_action_id,external_item_id,
       CASE WHEN BOOL_OR(NOT declared_is_demand_anchor AND declared_qty > 0)
            THEN SUM(declared_qty+runtime_qty)
            ELSE GREATEST(MAX(declared_qty),MAX(runtime_qty)) END::numeric
           AS source_limit_qty
FROM source_row
GROUP BY source_action_id,external_item_id;

CREATE OR REPLACE FUNCTION fn_preplan_public_source_approved_capacity(
    p_action_id UUID,p_external_item_id UUID
) RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE
    source_action preplan_supply_actions%ROWTYPE;
    source_limit NUMERIC(18,4) := 0;
    approved_qty NUMERIC(18,4) := 0;
    demand_anchor BOOLEAN;
    public_anchor BOOLEAN;
    baseline_qty NUMERIC(18,4) := 0;
BEGIN
    SELECT * INTO source_action FROM preplan_supply_actions
    WHERE id=p_action_id;
    SELECT COALESCE(MAX(source_limit_qty),0) INTO source_limit
    FROM v_preplan_public_supply_sources_v474
    WHERE source_action_id=p_action_id
      AND external_item_id=p_external_item_id;
    IF source_action.id IS NULL OR source_limit <= 0 THEN RETURN 0; END IF;
    SELECT EXISTS(
        SELECT 1 FROM preplan_supply_action_allocations allocation
        WHERE allocation.action_id=p_action_id
          AND allocation.external_item_id=p_external_item_id)
    INTO demand_anchor;
    public_anchor := source_action.public_surplus_external_item_id
        IS NOT DISTINCT FROM p_external_item_id;
    baseline_qty := CASE
        WHEN demand_anchor THEN source_action.requested_qty
        WHEN public_anchor THEN 0
        WHEN source_action.safety_external_item_id=p_external_item_id
            THEN source_action.safety_replenishment_qty
        ELSE 0 END;
    IF source_action.route='BUY' THEN
        SELECT COALESCE(SUM(fn_purchase_order_source_share(
                   item.id,source.request_item_id,
                   item.qty*COALESCE(item.unit_rate,1))),0)
        INTO approved_qty
        FROM purchase_order_item_sources source
        JOIN purchase_order_items item ON item.id=source.order_item_id
        JOIN purchase_orders header ON header.id=item.order_id
        WHERE source.request_item_id=p_external_item_id
          AND header.status=1 AND header.is_deleted=FALSE
          AND item.is_deleted=FALSE;
    ELSIF source_action.route='SUBCONTRACT' THEN
        SELECT COALESCE(SUM(fn_subcontract_order_source_share(
                   item.id,source.application_item_id,
                   item.qty*COALESCE(item.unit_rate,1))),0)
        INTO approved_qty
        FROM subcontract_order_item_sources source
        JOIN subcontract_order_items item ON item.id=source.order_item_id
        JOIN subcontract_orders header ON header.id=item.order_id
        WHERE source.application_item_id=p_external_item_id
          AND header.status=1 AND header.is_deleted=FALSE
          AND item.is_deleted=FALSE;
    END IF;
    RETURN LEAST(source_limit,GREATEST(approved_qty-baseline_qty,0));
END;
$$;

CREATE OR REPLACE FUNCTION fn_preplan_public_source_open_qty(
    p_action_id UUID,p_external_item_id UUID
) RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE
    source_action preplan_supply_actions%ROWTYPE;
    open_qty NUMERIC(18,4) := 0;
    demand_open NUMERIC(18,4) := 0;
    demand_anchor BOOLEAN;
    safety_anchor BOOLEAN;
BEGIN
    SELECT * INTO source_action FROM preplan_supply_actions WHERE id=p_action_id;
    IF source_action.id IS NULL THEN RETURN 0; END IF;
    SELECT EXISTS(
        SELECT 1 FROM preplan_supply_action_allocations allocation
        WHERE allocation.action_id=p_action_id
          AND allocation.external_item_id=p_external_item_id)
    INTO demand_anchor;
    safety_anchor := source_action.safety_external_item_id=p_external_item_id;
    demand_open := CASE
        WHEN demand_anchor THEN GREATEST(source_action.requested_qty
            - fn_preplan_action_effective_exact_qty(source_action.id),0)
        WHEN safety_anchor THEN source_action.safety_replenishment_qty
        ELSE 0 END;
    IF source_action.route='BUY' THEN
        SELECT COALESCE(SUM(GREATEST(
            fn_purchase_order_source_share(item.id,source.request_item_id,
                item.qty*COALESCE(item.unit_rate,1))
            - fn_purchase_order_source_share(item.id,source.request_item_id,
                GREATEST(COALESCE(item.received_qty,0)
                    -COALESCE(item.returned_qty,0),0)
                    *COALESCE(item.unit_rate,1)),0)),0)
        INTO open_qty
        FROM purchase_order_item_sources source
        JOIN purchase_order_items item ON item.id=source.order_item_id
        JOIN purchase_orders header ON header.id=item.order_id
        WHERE source.request_item_id=p_external_item_id
          AND header.status=1 AND header.is_deleted=FALSE
          AND header.is_closed=FALSE AND item.is_deleted=FALSE;
    ELSIF source_action.route='SUBCONTRACT' THEN
        SELECT COALESCE(SUM(GREATEST(
            fn_subcontract_order_source_share(item.id,source.application_item_id,
                item.qty*COALESCE(item.unit_rate,1))
            - fn_subcontract_order_source_share(item.id,source.application_item_id,
                GREATEST(COALESCE(item.received_qty,0)
                    -COALESCE(item.returned_qty,0),0)
                    *COALESCE(item.unit_rate,1)),0)),0)
        INTO open_qty
        FROM subcontract_order_item_sources source
        JOIN subcontract_order_items item ON item.id=source.order_item_id
        JOIN subcontract_orders header ON header.id=item.order_id
        WHERE source.application_item_id=p_external_item_id
          AND header.status=1 AND header.is_deleted=FALSE
          AND header.is_closed=FALSE AND item.is_deleted=FALSE;
    END IF;
    RETURN LEAST(
        fn_preplan_public_source_approved_capacity(
            source_action.id,p_external_item_id),
        GREATEST(open_qty-demand_open,0));
END;
$$;

CREATE OR REPLACE FUNCTION fn_preplan_public_surplus_approved_capacity(
    p_action_id UUID
) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(fn_preplan_public_source_approved_capacity(
        source_action_id,external_item_id)),0)
    FROM v_preplan_public_supply_sources_v474
    WHERE source_action_id=p_action_id;
$$;

CREATE OR REPLACE FUNCTION fn_preplan_public_surplus_open_qty(
    p_action_id UUID
) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(fn_preplan_public_source_open_qty(
        source_action_id,external_item_id)),0)
    FROM v_preplan_public_supply_sources_v474
    WHERE source_action_id=p_action_id;
$$;

-- Deterministically assigns an external item's public slice to approved orders
-- in bill-date/id order. This prevents a later over-order receipt from consuming
-- exact demand that belongs to an earlier under-filled order (and vice versa).
CREATE OR REPLACE FUNCTION fn_preplan_order_public_source_qty(
    p_action_id UUID,p_external_item_id UUID,
    p_order_type TEXT,p_order_id UUID
) RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE
    source_action preplan_supply_actions%ROWTYPE;
    baseline_qty NUMERIC(18,4);
    demand_anchor BOOLEAN;
    current_share NUMERIC(18,4) := 0;
    prior_share NUMERIC(18,4) := 0;
    total_capacity NUMERIC(18,4) := 0;
    raw_before NUMERIC(18,4);
    raw_after NUMERIC(18,4);
BEGIN
    SELECT * INTO source_action FROM preplan_supply_actions
    WHERE id=p_action_id;
    IF source_action.id IS NULL THEN RETURN 0; END IF;
    SELECT EXISTS(
        SELECT 1 FROM preplan_supply_action_allocations allocation
        WHERE allocation.action_id=p_action_id
          AND allocation.external_item_id=p_external_item_id)
    INTO demand_anchor;
    baseline_qty := CASE
        WHEN demand_anchor THEN source_action.requested_qty
        WHEN source_action.public_surplus_external_item_id=p_external_item_id
            THEN 0
        WHEN source_action.safety_external_item_id=p_external_item_id
            THEN source_action.safety_replenishment_qty
        ELSE NULL END;
    IF baseline_qty IS NULL THEN RETURN 0; END IF;
    total_capacity := fn_preplan_public_source_approved_capacity(
        p_action_id,p_external_item_id);
    IF total_capacity <= 0 THEN RETURN 0; END IF;
    IF p_order_type='PURCHASE' THEN
        SELECT COALESCE(SUM(fn_purchase_order_source_share(
                   item.id,source.request_item_id,
                   item.qty*COALESCE(item.unit_rate,1))) FILTER (
                       WHERE header.id=p_order_id),0),
               COALESCE(SUM(fn_purchase_order_source_share(
                   item.id,source.request_item_id,
                   item.qty*COALESCE(item.unit_rate,1))) FILTER (
                       WHERE (header.bill_date,header.id)
                           < (target.bill_date,target.id)),0)
        INTO current_share,prior_share
        FROM purchase_order_item_sources source
        JOIN purchase_order_items item ON item.id=source.order_item_id
        JOIN purchase_orders header ON header.id=item.order_id
        JOIN purchase_orders target ON target.id=p_order_id
        WHERE source.request_item_id=p_external_item_id
          AND header.status=1 AND header.is_deleted=FALSE
          AND item.is_deleted=FALSE;
    ELSIF p_order_type='SUBCONTRACT' THEN
        SELECT COALESCE(SUM(fn_subcontract_order_source_share(
                   item.id,source.application_item_id,
                   item.qty*COALESCE(item.unit_rate,1))) FILTER (
                       WHERE header.id=p_order_id),0),
               COALESCE(SUM(fn_subcontract_order_source_share(
                   item.id,source.application_item_id,
                   item.qty*COALESCE(item.unit_rate,1))) FILTER (
                       WHERE (header.bill_date,header.id)
                           < (target.bill_date,target.id)),0)
        INTO current_share,prior_share
        FROM subcontract_order_item_sources source
        JOIN subcontract_order_items item ON item.id=source.order_item_id
        JOIN subcontract_orders header ON header.id=item.order_id
        JOIN subcontract_orders target ON target.id=p_order_id
        WHERE source.application_item_id=p_external_item_id
          AND header.status=1 AND header.is_deleted=FALSE
          AND item.is_deleted=FALSE;
    ELSE RETURN 0;
    END IF;
    raw_before := GREATEST(prior_share-baseline_qty,0);
    raw_after := GREATEST(prior_share+current_share-baseline_qty,0);
    RETURN LEAST(
        GREATEST(raw_after-raw_before,0),
        GREATEST(total_capacity-raw_before,0));
END;
$$;

CREATE OR REPLACE FUNCTION fn_preplan_order_exact_attributed_qty(
    p_order_type TEXT,p_order_id UUID,p_external_item_id UUID,
    p_operation_type TEXT
) RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE attributed NUMERIC(18,4) := 0;
BEGIN
    IF p_order_type='PURCHASE' THEN
        SELECT COALESCE(SUM(CASE
                   WHEN reservation.release_reason='TRANSFERRED_TO_PLAN'
                       THEN exact.qty
                   ELSE GREATEST(reservation.qty-reservation.consumed_qty
                       -reservation.released_qty,0) END),0) INTO attributed
        FROM preplan_analysis_stock_exact_pegs exact
        JOIN stock_reservations reservation
          ON reservation.id=exact.stock_reservation_id
         AND reservation.is_deleted=FALSE
        JOIN preplan_supply_action_allocations allocation
          ON allocation.id=exact.supply_action_allocation_id
         AND allocation.external_item_id=p_external_item_id
        JOIN preplan_supply_actions action ON action.id=allocation.action_id
         AND action.operation_type=p_operation_type
        JOIN procurement_inspection_events event
          ON event.id=exact.source_disposition_event_id
        JOIN procurement_inspection_items inspection
          ON inspection.id=event.inspection_item_id
         AND inspection.receipt_type='PURCHASE'
        JOIN purchase_receipt_items receipt_item
          ON receipt_item.id=inspection.receipt_item_id
        JOIN purchase_order_items order_item
          ON order_item.id=receipt_item.order_item_id
        WHERE order_item.order_id=p_order_id
          AND inspection.status <> 'REVERSED'
          AND (reservation.status=0
               OR reservation.release_reason='TRANSFERRED_TO_PLAN');
    ELSIF p_order_type='SUBCONTRACT' THEN
        SELECT COALESCE(SUM(CASE
                   WHEN reservation.release_reason='TRANSFERRED_TO_PLAN'
                       THEN exact.qty
                   ELSE GREATEST(reservation.qty-reservation.consumed_qty
                       -reservation.released_qty,0) END),0) INTO attributed
        FROM preplan_analysis_stock_exact_pegs exact
        JOIN stock_reservations reservation
          ON reservation.id=exact.stock_reservation_id
         AND reservation.is_deleted=FALSE
        JOIN preplan_supply_action_allocations allocation
          ON allocation.id=exact.supply_action_allocation_id
         AND allocation.external_item_id=p_external_item_id
        JOIN preplan_supply_actions action ON action.id=allocation.action_id
         AND action.operation_type=p_operation_type
        JOIN procurement_inspection_events event
          ON event.id=exact.source_disposition_event_id
        JOIN procurement_inspection_items inspection
          ON inspection.id=event.inspection_item_id
         AND inspection.receipt_type='SUBCONTRACT'
        JOIN subcontract_receipt_items receipt_item
          ON receipt_item.id=inspection.receipt_item_id
        JOIN subcontract_order_items order_item
          ON order_item.id=receipt_item.order_item_id
        WHERE order_item.order_id=p_order_id
          AND inspection.status <> 'REVERSED'
          AND (reservation.status=0
               OR reservation.release_reason='TRANSFERRED_TO_PLAN');
    END IF;
    RETURN attributed;
END;
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
               -fn_preplan_action_effective_exact_qty(id),0))::numeric
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
          AND header.is_closed=FALSE AND item.is_deleted=FALSE
        UNION ALL
        SELECT COALESCE(item.deliver_date,header.deliver_date)
        FROM subcontract_order_item_sources link
        JOIN subcontract_order_items item ON item.id=link.order_item_id
        JOIN subcontract_orders header ON header.id=item.order_id
        WHERE source.route='SUBCONTRACT'
          AND link.application_item_id=source.claim_external_item_id
          AND header.status=1 AND header.is_deleted=FALSE
          AND header.is_closed=FALSE AND item.is_deleted=FALSE
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

CREATE OR REPLACE FUNCTION fn_validate_preplan_shared_future_claim()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    claim_action preplan_supply_actions%ROWTYPE;
    source_action preplan_supply_actions%ROWTYPE;
    allocation_total NUMERIC(18,4);
    other_claim_total NUMERIC(18,4);
    other_claim_open NUMERIC(18,4);
    current_claim_open NUMERIC(18,4);
    expected_item UUID;
    allocation_item_count INTEGER;
BEGIN
    IF TG_TABLE_NAME='preplan_supply_action_allocations' THEN
        SELECT * INTO claim_action FROM preplan_supply_actions
        WHERE id=COALESCE(NEW.action_id,OLD.action_id);
    ELSE claim_action:=NEW; END IF;
    IF claim_action.operation_type <> 'SHARED_FUTURE_CLAIM' THEN RETURN NULL; END IF;
    SELECT * INTO source_action FROM preplan_supply_actions
    WHERE id=claim_action.claim_source_action_id FOR UPDATE;
    SELECT COALESCE(SUM(allocated_qty),0),
           min(external_item_id::text)::uuid,
           count(DISTINCT external_item_id)
    INTO allocation_total,expected_item,allocation_item_count
    FROM preplan_supply_action_allocations
    WHERE action_id=claim_action.id;
    SELECT COALESCE(SUM(other.requested_qty),0) INTO other_claim_total
    FROM preplan_supply_actions other
    JOIN preplan_supply_action_allocations allocation
      ON allocation.action_id=other.id
     AND allocation.external_item_id=expected_item
    WHERE other.claim_source_action_id=source_action.id
      AND other.operation_type='SHARED_FUTURE_CLAIM'
      AND other.status <> 'CANCELLED' AND other.id <> claim_action.id;
    SELECT COALESCE(SUM(GREATEST(other.requested_qty
               -fn_preplan_action_effective_exact_qty(other.id),0)),0)
    INTO other_claim_open
    FROM preplan_supply_actions other
    JOIN preplan_supply_action_allocations allocation
      ON allocation.action_id=other.id
     AND allocation.external_item_id=expected_item
    WHERE other.claim_source_action_id=source_action.id
      AND other.operation_type='SHARED_FUTURE_CLAIM'
      AND other.status <> 'CANCELLED' AND other.id <> claim_action.id;
    current_claim_open := GREATEST(claim_action.requested_qty
        -fn_preplan_action_effective_exact_qty(claim_action.id),0);
    IF source_action.id IS NULL
       OR source_action.operation_type <> 'SUPPLY'
       OR source_action.status='CANCELLED'
       OR source_action.analysis_id=claim_action.analysis_id
       OR source_action.warehouse_id <> claim_action.warehouse_id
       OR source_action.goods_id <> claim_action.goods_id
       OR source_action.color_id IS DISTINCT FROM claim_action.color_id
       OR source_action.unit_id <> claim_action.unit_id
       OR source_action.route <> claim_action.route
       OR source_action.external_document_type <> claim_action.external_document_type
       OR source_action.external_document_id <> claim_action.external_document_id
       OR claim_action.status NOT IN ('CREATED','IN_PROGRESS','DONE','CANCELLED')
       OR expected_item IS NULL OR allocation_item_count <> 1
       OR allocation_total IS DISTINCT FROM claim_action.requested_qty
       OR fn_preplan_public_source_approved_capacity(
              source_action.id,expected_item) <= 0
       OR other_claim_total+claim_action.requested_qty
            > fn_preplan_public_source_approved_capacity(
                source_action.id,expected_item)
       OR other_claim_open+current_claim_open
            > fn_preplan_public_source_open_qty(
                source_action.id,expected_item) THEN
        RAISE EXCEPTION 'invalid or over-capacity shared future claim'
            USING ERRCODE='23514',
                  CONSTRAINT='preplan_shared_future_claim_capacity_guard';
    END IF;
    RETURN NULL;
END;
$$;

-- Existing V472 triggers retain these function names, so replacing the bodies
-- extends their protection to runtime demand/public/safety overorder sources.
CREATE OR REPLACE FUNCTION fn_guard_purchase_shared_future_source()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM purchase_order_item_sources order_source
        JOIN v_preplan_public_supply_sources_v474 public
          ON public.external_item_id=order_source.request_item_id
        JOIN preplan_supply_actions claim
          ON claim.claim_source_action_id=public.source_action_id
         AND claim.operation_type='SHARED_FUTURE_CLAIM'
         AND claim.status <> 'CANCELLED'
        JOIN preplan_supply_action_allocations allocation
          ON allocation.action_id=claim.id
         AND allocation.external_item_id=public.external_item_id
        WHERE order_source.order_item_id=OLD.id) THEN
        RAISE EXCEPTION 'purchase source has active shared future claims'
            USING ERRCODE='23514',
                  CONSTRAINT='purchase_shared_future_source_guard';
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_subcontract_shared_future_source()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM subcontract_order_item_sources order_source
        JOIN v_preplan_public_supply_sources_v474 public
          ON public.external_item_id=order_source.application_item_id
        JOIN preplan_supply_actions claim
          ON claim.claim_source_action_id=public.source_action_id
         AND claim.operation_type='SHARED_FUTURE_CLAIM'
         AND claim.status <> 'CANCELLED'
        JOIN preplan_supply_action_allocations allocation
          ON allocation.action_id=claim.id
         AND allocation.external_item_id=public.external_item_id
        WHERE order_source.order_item_id=OLD.id) THEN
        RAISE EXCEPTION 'subcontract source has active shared future claims'
            USING ERRCODE='23514',
                  CONSTRAINT='subcontract_shared_future_source_guard';
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_purchase_shared_future_source_header()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.status IS DISTINCT FROM OLD.status
        OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted
        OR (NEW.is_closed IS DISTINCT FROM OLD.is_closed
            AND NEW.is_closed=TRUE
            AND EXISTS (
                SELECT 1 FROM purchase_order_items open_item
                WHERE open_item.order_id=OLD.id
                  AND open_item.is_deleted=FALSE
                  AND COALESCE(open_item.qty,0)
                      -COALESCE(open_item.received_qty,0)
                      +COALESCE(open_item.returned_qty,0) > 0)))
       AND EXISTS (
        SELECT 1 FROM purchase_order_items item
        JOIN purchase_order_item_sources order_source
          ON order_source.order_item_id=item.id
        JOIN v_preplan_public_supply_sources_v474 public
          ON public.external_item_id=order_source.request_item_id
        JOIN preplan_supply_actions claim
          ON claim.claim_source_action_id=public.source_action_id
         AND claim.status <> 'CANCELLED'
        JOIN preplan_supply_action_allocations allocation
          ON allocation.action_id=claim.id
         AND allocation.external_item_id=public.external_item_id
        WHERE item.order_id=OLD.id) THEN
        RAISE EXCEPTION 'purchase order has active shared future claims'
            USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_guard_subcontract_shared_future_source_header()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.status IS DISTINCT FROM OLD.status
        OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted
        OR (NEW.is_closed IS DISTINCT FROM OLD.is_closed
            AND NEW.is_closed=TRUE
            AND EXISTS (
                SELECT 1 FROM subcontract_order_items open_item
                WHERE open_item.order_id=OLD.id
                  AND open_item.is_deleted=FALSE
                  AND COALESCE(open_item.qty,0)
                      -COALESCE(open_item.received_qty,0)
                      +COALESCE(open_item.returned_qty,0) > 0)))
       AND EXISTS (
        SELECT 1 FROM subcontract_order_items item
        JOIN subcontract_order_item_sources order_source
          ON order_source.order_item_id=item.id
        JOIN v_preplan_public_supply_sources_v474 public
          ON public.external_item_id=order_source.application_item_id
        JOIN preplan_supply_actions claim
          ON claim.claim_source_action_id=public.source_action_id
         AND claim.status <> 'CANCELLED'
        JOIN preplan_supply_action_allocations allocation
          ON allocation.action_id=claim.id
         AND allocation.external_item_id=public.external_item_id
        WHERE item.order_id=OLD.id) THEN
        RAISE EXCEPTION 'subcontract order has active shared future claims'
            USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;

-- Replace the event validator now that public and safety anchors are supported.
CREATE OR REPLACE FUNCTION fn_check_preplan_public_supply_event()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    action preplan_supply_actions%ROWTYPE;
    current_qty NUMERIC(18,4);
    capacity NUMERIC(18,4);
    next_qty NUMERIC(18,4);
    order_valid BOOLEAN;
    anchor_valid BOOLEAN;
BEGIN
    SELECT * INTO action FROM preplan_supply_actions
    WHERE id=NEW.source_action_id FOR UPDATE;
    SELECT EXISTS(
        SELECT 1 FROM preplan_supply_action_allocations allocation
        WHERE allocation.action_id=NEW.source_action_id
          AND allocation.external_item_id=NEW.source_external_item_id)
        OR action.public_surplus_external_item_id=NEW.source_external_item_id
        OR action.safety_external_item_id=NEW.source_external_item_id
    INTO anchor_valid;
    current_qty := fn_preplan_runtime_public_supply_balance(
        NEW.source_action_id,NEW.source_external_item_id);
    capacity := fn_preplan_direct_overorder_capacity(
        NEW.source_action_id,NEW.source_external_item_id);
    IF NEW.trigger_order_type='PURCHASE' THEN
        SELECT EXISTS(
            SELECT 1 FROM purchase_orders header
            JOIN purchase_order_items item ON item.order_id=header.id
             AND item.is_deleted=FALSE
            JOIN purchase_order_item_sources source
              ON source.order_item_id=item.id
             AND source.request_item_id=NEW.source_external_item_id
            WHERE header.id=NEW.trigger_order_id
              AND header.status=CASE NEW.event_type
                  WHEN 'GRANT' THEN 1 ELSE -1 END)
        INTO order_valid;
    ELSE
        SELECT EXISTS(
            SELECT 1 FROM subcontract_orders header
            JOIN subcontract_order_items item ON item.order_id=header.id
             AND item.is_deleted=FALSE
            JOIN subcontract_order_item_sources source
              ON source.order_item_id=item.id
             AND source.application_item_id=NEW.source_external_item_id
            WHERE header.id=NEW.trigger_order_id
              AND header.status=CASE NEW.event_type
                  WHEN 'GRANT' THEN 1 ELSE -1 END)
        INTO order_valid;
    END IF;
    IF action.id IS NULL OR NOT COALESCE(order_valid,FALSE)
       OR NOT COALESCE(anchor_valid,FALSE)
       OR action.operation_type <> 'SUPPLY'
       OR action.warehouse_id <> NEW.warehouse_id
       OR action.goods_id <> NEW.goods_id
       OR action.color_id IS DISTINCT FROM NEW.color_id
       OR action.unit_id <> NEW.unit_id OR action.route <> NEW.route
       OR (NEW.trigger_order_type='PURCHASE' AND action.route <> 'BUY')
       OR (NEW.trigger_order_type='SUBCONTRACT'
           AND action.route <> 'SUBCONTRACT') THEN
        RAISE EXCEPTION 'invalid runtime public supply event identity'
            USING ERRCODE='23514';
    END IF;
    next_qty := current_qty + CASE NEW.event_type
        WHEN 'GRANT' THEN NEW.qty ELSE -NEW.qty END;
    IF next_qty < 0 OR next_qty > capacity THEN
        RAISE EXCEPTION 'runtime public supply event leaves invalid balance'
            USING ERRCODE='23514',
                  CONSTRAINT='preplan_public_supply_event_balance_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_preplan_public_supply_event
    BEFORE INSERT ON preplan_public_supply_events
    FOR EACH ROW EXECUTE FUNCTION fn_check_preplan_public_supply_event();

-- Complete the cutover backfill across demand, explicit-public and safety
-- request/application items. It is intentionally after the all-anchor helper.
WITH anchor AS (
    SELECT action.id AS action_id,allocation.external_item_id,
           'DEMAND'::text AS anchor_kind
    FROM preplan_supply_actions action
    JOIN preplan_supply_action_allocations allocation
      ON allocation.action_id=action.id
     AND allocation.external_item_id IS NOT NULL
    WHERE action.operation_type='SUPPLY' AND action.status <> 'CANCELLED'
    UNION
    SELECT id,public_surplus_external_item_id,'PUBLIC'
    FROM preplan_supply_actions
    WHERE operation_type='SUPPLY' AND status <> 'CANCELLED'
      AND public_surplus_external_item_id IS NOT NULL
    UNION
    SELECT id,safety_external_item_id,'SAFETY'
    FROM preplan_supply_actions
    WHERE operation_type='SUPPLY' AND status <> 'CANCELLED'
      AND safety_external_item_id IS NOT NULL
), candidate AS (
    SELECT action.id AS action_id,anchor.external_item_id,anchor.anchor_kind,
           action.warehouse_id,action.goods_id,action.color_id,
           action.unit_id,action.route,action.created_by,
           fn_preplan_direct_overorder_capacity(
               action.id,anchor.external_item_id) AS capacity,
           fn_preplan_runtime_public_supply_balance(
               action.id,anchor.external_item_id) AS captured,
           CASE WHEN anchor.anchor_kind='DEMAND'
                     AND action.public_surplus_external_item_id
                         =anchor.external_item_id
                THEN action.public_surplus_qty ELSE 0 END AS legacy_declared,
           CASE action.route WHEN 'BUY' THEN (
               SELECT item.order_id
               FROM purchase_order_item_sources source
               JOIN purchase_order_items item ON item.id=source.order_item_id
               JOIN purchase_orders header ON header.id=item.order_id
               WHERE source.request_item_id=anchor.external_item_id
                 AND header.status=1 AND header.is_deleted=FALSE
                 AND item.is_deleted=FALSE
               ORDER BY header.bill_date DESC,header.id DESC LIMIT 1)
           ELSE (
               SELECT item.order_id
               FROM subcontract_order_item_sources source
               JOIN subcontract_order_items item ON item.id=source.order_item_id
               JOIN subcontract_orders header ON header.id=item.order_id
               WHERE source.application_item_id=anchor.external_item_id
                 AND header.status=1 AND header.is_deleted=FALSE
                 AND item.is_deleted=FALSE
               ORDER BY header.bill_date DESC,header.id DESC LIMIT 1)
           END AS order_id
    FROM anchor JOIN preplan_supply_actions action ON action.id=anchor.action_id
), normalized AS (
    SELECT candidate.*,
           CASE WHEN anchor_kind='DEMAND' AND legacy_declared>=capacity
                THEN 0 ELSE capacity END AS target_runtime
    FROM candidate
)
INSERT INTO preplan_public_supply_events(
    id,source_action_id,source_external_item_id,
    trigger_order_type,trigger_order_id,event_type,qty,
    warehouse_id,goods_id,color_id,unit_id,route,
    idempotency_key,created_by)
SELECT gen_random_uuid(),action_id,external_item_id,
       CASE route WHEN 'BUY' THEN 'PURCHASE' ELSE 'SUBCONTRACT' END,
       order_id,'GRANT',target_runtime-captured,
       warehouse_id,goods_id,color_id,unit_id,route,
       'V474-ALL-ANCHOR:' || action_id || ':' || external_item_id,
       created_by
FROM normalized
WHERE order_id IS NOT NULL AND target_runtime>captured
ON CONFLICT (idempotency_key) DO NOTHING;

-- New exact lots may never be attributed across source action/analysis main
-- warehouses. Historical mismatches remain visible and are not rewritten.
CREATE VIEW v_preplan_exact_peg_warehouse_mismatches AS
SELECT exact.id AS exact_peg_id,exact.stock_reservation_id,
       exact.origin_analysis_id,exact.beneficiary_analysis_id,
       action.id AS source_action_id,
       reservation.warehouse_id AS reservation_warehouse_id,
       action.warehouse_id AS action_warehouse_id,
       origin_analysis.warehouse_id AS origin_analysis_warehouse_id,
       beneficiary_analysis.warehouse_id AS beneficiary_analysis_warehouse_id
FROM preplan_analysis_stock_exact_pegs exact
JOIN stock_reservations reservation ON reservation.id=exact.stock_reservation_id
JOIN preplan_supply_action_allocations allocation
  ON allocation.id=exact.supply_action_allocation_id
JOIN preplan_supply_actions action ON action.id=allocation.action_id
JOIN production_material_analyses origin_analysis
  ON origin_analysis.id=exact.origin_analysis_id
JOIN production_material_analyses beneficiary_analysis
  ON beneficiary_analysis.id=exact.beneficiary_analysis_id
WHERE reservation.warehouse_id IS DISTINCT FROM action.warehouse_id
   OR reservation.warehouse_id IS DISTINCT FROM origin_analysis.warehouse_id
   OR reservation.warehouse_id IS DISTINCT FROM beneficiary_analysis.warehouse_id;

CREATE OR REPLACE FUNCTION fn_check_preplan_exact_peg_warehouse_v474()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM v_preplan_exact_peg_warehouse_mismatches mismatch
               WHERE mismatch.exact_peg_id=NEW.id) THEN
        RAISE EXCEPTION 'preplan exact entitlement cannot cross the main warehouse'
            USING ERRCODE='23514',
                  CONSTRAINT='preplan_exact_peg_main_warehouse_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_check_preplan_exact_peg_warehouse_v474
    AFTER INSERT ON preplan_analysis_stock_exact_pegs
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW EXECUTE FUNCTION fn_check_preplan_exact_peg_warehouse_v474();

CREATE OR REPLACE FUNCTION fn_guard_preplan_exact_warehouse_identity_v474()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.warehouse_id IS NOT DISTINCT FROM OLD.warehouse_id THEN RETURN NEW; END IF;
    IF TG_TABLE_NAME='production_material_analyses' AND EXISTS (
        SELECT 1 FROM preplan_analysis_stock_exact_pegs exact
        WHERE exact.origin_analysis_id=OLD.id
           OR exact.beneficiary_analysis_id=OLD.id) THEN
        RAISE EXCEPTION 'analysis main warehouse is frozen by exact entitlement'
            USING ERRCODE='23514',
                  CONSTRAINT='preplan_exact_analysis_warehouse_immutable_guard';
    ELSIF TG_TABLE_NAME='preplan_supply_actions' AND EXISTS (
        SELECT 1 FROM preplan_supply_action_allocations allocation
        JOIN preplan_analysis_stock_exact_pegs exact
          ON exact.supply_action_allocation_id=allocation.id
        WHERE allocation.action_id=OLD.id) THEN
        RAISE EXCEPTION 'supply action warehouse is frozen by exact entitlement'
            USING ERRCODE='23514',
                  CONSTRAINT='preplan_exact_action_warehouse_immutable_guard';
    ELSIF TG_TABLE_NAME='stock_reservations' AND EXISTS (
        SELECT 1 FROM preplan_analysis_stock_exact_pegs exact
        WHERE exact.stock_reservation_id=OLD.id) THEN
        RAISE EXCEPTION 'reservation warehouse is frozen by exact entitlement'
            USING ERRCODE='23514',
                  CONSTRAINT='preplan_exact_reservation_warehouse_immutable_guard';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_preplan_exact_analysis_warehouse_v474
    BEFORE UPDATE OF warehouse_id ON production_material_analyses
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_exact_warehouse_identity_v474();
CREATE TRIGGER trg_guard_preplan_exact_action_warehouse_v474
    BEFORE UPDATE OF warehouse_id ON preplan_supply_actions
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_exact_warehouse_identity_v474();
CREATE TRIGGER trg_guard_preplan_exact_reservation_warehouse_v474
    BEFORE UPDATE OF warehouse_id ON stock_reservations
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_exact_warehouse_identity_v474();

-- Re-issue the already installed reset function with one mechanically inserted
-- CLEAR row. Fail closed if the expected V464 source fragment is absent.
-- business_data_reset() 的失败关闭机制是「未分类 public 表拒绝」（unknown_tables）
-- 与「分类重复拒绝」，没有按表数量的硬编码守卫；因此这里只需机械插入一行
-- CLEAR 策略并整函数重发，不触碰任何计数文本（V464 原文保持字节不变）。
DO $reset_patch$
DECLARE
    definition TEXT;
    patched TEXT;
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure)
    INTO definition;
    patched := replace(
        definition,
        '(''preplan_supply_actions'', ''CLEAR''),',
        '(''preplan_public_supply_events'', ''CLEAR''),' || E'\n    ' ||
        '(''preplan_supply_actions'', ''CLEAR''),');
    IF patched IS NOT DISTINCT FROM definition THEN
        RAISE EXCEPTION 'V474 cannot extend business_data_reset policy safely'
            USING ERRCODE='23514';
    END IF;
    EXECUTE patched;
END;
$reset_patch$;

COMMENT ON TABLE preplan_public_supply_events IS
    'V474 append-only finance-effective direct-overorder public supply adjustments';
COMMENT ON VIEW v_preplan_exact_peg_warehouse_mismatches IS
    'Historical reconciliation queue; new cross-main-warehouse exact entitlement is blocked';
