-- V152: production material issue/return accounting and final quantity guards.
--
-- Physical stock still moves through DRAW/WDRAW.  These tables only retain
-- the exact allocation split needed to update V150 stock_reservations
-- symmetrically; they are not a second stock balance.

CREATE TABLE production_material_stock_events (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    stock_document_id  UUID NOT NULL REFERENCES stock_documents(id),
    event_type         TEXT NOT NULL,
    idempotency_key    TEXT NOT NULL,
    request_hash       TEXT NOT NULL,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         UUID,
    CONSTRAINT production_material_stock_event_type_chk
        CHECK (event_type IN (
            'ISSUE', 'ISSUE_REVERSE', 'GOOD_RETURN', 'GOOD_RETURN_REVERSE'
        )),
    CONSTRAINT production_material_stock_event_key_chk
        CHECK (length(btrim(idempotency_key)) BETWEEN 8 AND 128),
    CONSTRAINT production_material_stock_event_hash_chk
        CHECK (length(request_hash) = 64)
);

CREATE UNIQUE INDEX uq_production_material_stock_event_request
    ON production_material_stock_events(
        stock_document_id, event_type, idempotency_key
    );

CREATE TABLE production_material_stock_postings (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id                UUID NOT NULL
                                REFERENCES production_material_stock_events(id)
                                ON DELETE CASCADE,
    stock_document_item_id  UUID NOT NULL REFERENCES stock_document_items(id),
    demand_id               UUID NOT NULL
                                REFERENCES production_material_demands(id),
    reservation_id          UUID NOT NULL REFERENCES stock_reservations(id),
    source_posting_id       UUID
                                REFERENCES production_material_stock_postings(id),
    posting_type            TEXT NOT NULL,
    qty_base                NUMERIC(18,4) NOT NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by              UUID,
    CONSTRAINT production_material_stock_posting_type_chk
        CHECK (posting_type IN (
            'ISSUE', 'ISSUE_REVERSE', 'GOOD_RETURN', 'GOOD_RETURN_REVERSE'
        )),
    CONSTRAINT production_material_stock_posting_qty_chk CHECK (qty_base > 0),
    CONSTRAINT production_material_stock_posting_source_chk CHECK (
        (posting_type = 'ISSUE' AND source_posting_id IS NULL)
        OR (posting_type <> 'ISSUE' AND source_posting_id IS NOT NULL)
    )
);

CREATE INDEX idx_production_material_stock_posting_item
    ON production_material_stock_postings(
        stock_document_item_id, posting_type, created_at, id
    );
CREATE INDEX idx_production_material_stock_posting_reservation
    ON production_material_stock_postings(reservation_id, created_at, id);
CREATE INDEX idx_production_material_stock_posting_source
    ON production_material_stock_postings(source_posting_id)
    WHERE source_posting_id IS NOT NULL;

-- Current material reconciliation projection.  ISSUE_REVERSE changes net
-- issued; GOOD_RETURN is displayed separately.  Actual consumption/loss/WIP
-- remains zero until a dedicated shop-floor confirmation is posted, therefore
-- can_close fails closed instead of treating issued-minus-returned as usage.
CREATE OR REPLACE VIEW v_production_material_clearance AS
WITH issue AS (
    SELECT p.demand_id,
           SUM(CASE p.posting_type
                   WHEN 'ISSUE' THEN p.qty_base
                   WHEN 'ISSUE_REVERSE' THEN -p.qty_base
                   ELSE 0 END) AS issued_qty,
           SUM(CASE p.posting_type
                   WHEN 'GOOD_RETURN' THEN p.qty_base
                   WHEN 'GOOD_RETURN_REVERSE' THEN -p.qty_base
                   ELSE 0 END) AS returned_qty
    FROM production_material_stock_postings p
    GROUP BY p.demand_id
)
SELECT d.plan_id,
       d.id AS demand_id,
       d.goods_id,
       d.color_id,
       d.required_qty,
       COALESCE(i.issued_qty, 0) AS issued_qty,
       COALESCE(i.returned_qty, 0) AS returned_qty,
       0::numeric AS confirmed_consumed_qty,
       0::numeric AS approved_loss_qty,
       0::numeric AS legal_wip_qty,
       COALESCE(i.issued_qty, 0) - COALESCE(i.returned_qty, 0)
           AS uncleared_qty,
       COALESCE(i.issued_qty, 0) = COALESCE(i.returned_qty, 0)
           AS can_close
FROM production_material_demands d
LEFT JOIN issue i ON i.demand_id = d.id
WHERE d.is_deleted = FALSE
  AND d.status NOT IN ('RELEASED', 'REVERSED');

COMMENT ON VIEW v_production_material_clearance IS
    'Fail-closed material clearing: issue = confirmed use + good return + approved loss + legal WIP. Use/loss/WIP need a later explicit confirmation ledger; they are never inferred.';

-- Historical rows may contain inbound greater than reported production.
-- Keep them visible for reconciliation, but reject every new or modified
-- violation immediately.
ALTER TABLE plan_order_item_links
    ADD CONSTRAINT plan_order_item_links_quantity_order_chk
    CHECK (
        COALESCE(inbound_qty, 0) >= 0
        AND COALESCE(produced_qty, 0) >= COALESCE(inbound_qty, 0)
        AND allocated_qty >= COALESCE(produced_qty, 0)
    ) NOT VALID;

-- All lifecycle rows are visible in System Management > audit log.
CREATE TRIGGER trg_audit_production_material_stock_events
    AFTER INSERT OR UPDATE OR DELETE ON production_material_stock_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_material_stock_postings
    AFTER INSERT OR UPDATE OR DELETE ON production_material_stock_postings
    FOR EACH ROW EXECUTE FUNCTION fn_audit();


-- Explicit shop-floor material settlement.  Consumption, approved loss and
-- legal WIP are never inferred from BOM or from issue-minus-return.
CREATE TABLE production_material_settlement_events (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id          UUID NOT NULL REFERENCES production_plans(id),
    event_type       TEXT NOT NULL,
    idempotency_key  TEXT NOT NULL,
    request_hash     TEXT NOT NULL,
    reason           TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       UUID,
    CONSTRAINT production_material_settlement_event_type_chk
        CHECK (event_type IN ('POST', 'REVERSE')),
    CONSTRAINT production_material_settlement_event_key_chk
        CHECK (length(btrim(idempotency_key)) BETWEEN 8 AND 128),
    CONSTRAINT production_material_settlement_event_hash_chk
        CHECK (length(request_hash) = 64)
);

CREATE UNIQUE INDEX uq_production_material_settlement_event_request
    ON production_material_settlement_events(
        plan_id, event_type, idempotency_key
    );

CREATE TABLE production_material_settlement_postings (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id           UUID NOT NULL
                           REFERENCES production_material_settlement_events(id)
                           ON DELETE CASCADE,
    demand_id          UUID NOT NULL REFERENCES production_material_demands(id),
    settlement_type    TEXT NOT NULL,
    qty_base           NUMERIC(18,4) NOT NULL,
    source_posting_id  UUID
                           REFERENCES production_material_settlement_postings(id),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         UUID,
    CONSTRAINT production_material_settlement_type_chk
        CHECK (settlement_type IN (
            'CONSUMED', 'APPROVED_LOSS', 'LEGAL_WIP'
        )),
    CONSTRAINT production_material_settlement_qty_chk CHECK (qty_base > 0)
);

CREATE INDEX idx_production_material_settlement_demand
    ON production_material_settlement_postings(
        demand_id, settlement_type, created_at, id
    );
CREATE INDEX idx_production_material_settlement_source
    ON production_material_settlement_postings(source_posting_id)
    WHERE source_posting_id IS NOT NULL;

CREATE OR REPLACE FUNCTION fn_guard_production_material_settlement()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_event_type text;
    v_event_plan uuid;
    v_demand_plan uuid;
    v_source production_material_settlement_postings%ROWTYPE;
    v_reversed numeric;
    v_issued numeric;
    v_returned numeric;
    v_settled numeric;
BEGIN
    SELECT event_type, plan_id
    INTO v_event_type, v_event_plan
    FROM production_material_settlement_events
    WHERE id = NEW.event_id
    FOR UPDATE;

    PERFORM 1
    FROM production_plans
    WHERE id = v_event_plan
      AND is_deleted = FALSE
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'settlement plan is not active'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_settlement_plan_guard';
    END IF;

    SELECT plan_id INTO v_demand_plan
    FROM production_material_demands
    WHERE id = NEW.demand_id
      AND is_deleted = FALSE
      AND status NOT IN ('RELEASED', 'REVERSED')
    FOR UPDATE;

    IF v_event_type IS NULL OR v_demand_plan IS NULL
       OR v_event_plan <> v_demand_plan THEN
        RAISE EXCEPTION 'settlement demand does not belong to active plan'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_settlement_plan_guard';
    END IF;

    IF v_event_type = 'POST' THEN
        IF NEW.source_posting_id IS NOT NULL THEN
            RAISE EXCEPTION 'positive settlement cannot reference a source'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_material_settlement_source_guard';
        END IF;

        SELECT COALESCE(SUM(CASE posting_type
                   WHEN 'ISSUE' THEN qty_base
                   WHEN 'ISSUE_REVERSE' THEN -qty_base
                   ELSE 0 END), 0),
               COALESCE(SUM(CASE posting_type
                   WHEN 'GOOD_RETURN' THEN qty_base
                   WHEN 'GOOD_RETURN_REVERSE' THEN -qty_base
                   ELSE 0 END), 0)
        INTO v_issued, v_returned
        FROM production_material_stock_postings
        WHERE demand_id = NEW.demand_id;

        SELECT COALESCE(SUM(
                   CASE e.event_type
                       WHEN 'POST' THEN p.qty_base
                       ELSE -p.qty_base
                   END
               ), 0)
        INTO v_settled
        FROM production_material_settlement_postings p
        JOIN production_material_settlement_events e ON e.id = p.event_id
        WHERE p.demand_id = NEW.demand_id;

        IF v_settled + NEW.qty_base > v_issued - v_returned THEN
            RAISE EXCEPTION 'settlement exceeds net issued quantity'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_material_settlement_capacity_guard';
        END IF;
    ELSE
        IF NEW.source_posting_id IS NULL THEN
            RAISE EXCEPTION 'settlement reversal requires source posting'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_material_settlement_source_guard';
        END IF;

        SELECT * INTO v_source
        FROM production_material_settlement_postings
        WHERE id = NEW.source_posting_id
        FOR UPDATE;

        IF NOT FOUND
           OR v_source.source_posting_id IS NOT NULL
           OR v_source.demand_id <> NEW.demand_id
           OR v_source.settlement_type <> NEW.settlement_type THEN
            RAISE EXCEPTION 'settlement reversal source is invalid'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_material_settlement_reverse_guard';
        END IF;

        SELECT COALESCE(SUM(p.qty_base), 0)
        INTO v_reversed
        FROM production_material_settlement_postings p
        JOIN production_material_settlement_events e ON e.id = p.event_id
        WHERE p.source_posting_id = NEW.source_posting_id
          AND e.event_type = 'REVERSE';

        IF v_reversed + NEW.qty_base > v_source.qty_base THEN
            RAISE EXCEPTION 'settlement reversal exceeds source quantity'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_material_settlement_reverse_capacity_guard';
        END IF;
    END IF;
    UPDATE production_plans
    SET is_closed = FALSE,
        updated_at = now()
    WHERE id = v_event_plan
      AND is_closed = TRUE;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_material_settlement
    BEFORE INSERT OR UPDATE ON production_material_settlement_postings
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_material_settlement();

CREATE OR REPLACE VIEW v_production_material_clearance AS
WITH stock AS (
    SELECT demand_id,
           SUM(CASE posting_type
                   WHEN 'ISSUE' THEN qty_base
                   WHEN 'ISSUE_REVERSE' THEN -qty_base
                   ELSE 0 END) AS issued_qty,
           SUM(CASE posting_type
                   WHEN 'GOOD_RETURN' THEN qty_base
                   WHEN 'GOOD_RETURN_REVERSE' THEN -qty_base
                   ELSE 0 END) AS returned_qty
    FROM production_material_stock_postings
    GROUP BY demand_id
),
settled AS (
    SELECT p.demand_id,
           SUM(CASE WHEN p.settlement_type = 'CONSUMED'
                    THEN CASE e.event_type WHEN 'POST' THEN p.qty_base
                         ELSE -p.qty_base END ELSE 0 END) AS consumed_qty,
           SUM(CASE WHEN p.settlement_type = 'APPROVED_LOSS'
                    THEN CASE e.event_type WHEN 'POST' THEN p.qty_base
                         ELSE -p.qty_base END ELSE 0 END) AS loss_qty,
           SUM(CASE WHEN p.settlement_type = 'LEGAL_WIP'
                    THEN CASE e.event_type WHEN 'POST' THEN p.qty_base
                         ELSE -p.qty_base END ELSE 0 END) AS wip_qty
    FROM production_material_settlement_postings p
    JOIN production_material_settlement_events e ON e.id = p.event_id
    GROUP BY p.demand_id
)
SELECT d.plan_id,
       d.id AS demand_id,
       d.goods_id,
       d.color_id,
       d.required_qty,
       COALESCE(s.issued_qty, 0) AS issued_qty,
       COALESCE(s.returned_qty, 0) AS returned_qty,
       COALESCE(x.consumed_qty, 0) AS confirmed_consumed_qty,
       COALESCE(x.loss_qty, 0) AS approved_loss_qty,
       COALESCE(x.wip_qty, 0) AS legal_wip_qty,
       COALESCE(s.issued_qty, 0) - COALESCE(s.returned_qty, 0)
         - COALESCE(x.consumed_qty, 0) - COALESCE(x.loss_qty, 0)
         - COALESCE(x.wip_qty, 0) AS uncleared_qty,
       COALESCE(s.issued_qty, 0) > 0
         AND COALESCE(s.issued_qty, 0) - COALESCE(s.returned_qty, 0)
           = COALESCE(x.consumed_qty, 0) + COALESCE(x.loss_qty, 0)
             + COALESCE(x.wip_qty, 0) AS can_close
FROM production_material_demands d
LEFT JOIN stock s ON s.demand_id = d.id
LEFT JOIN settled x ON x.demand_id = d.id
WHERE d.is_deleted = FALSE
  AND d.status NOT IN ('RELEASED', 'REVERSED');

CREATE TRIGGER trg_audit_production_material_settlement_events
    AFTER INSERT OR UPDATE OR DELETE ON production_material_settlement_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_production_material_settlement_postings
    AFTER INSERT OR UPDATE OR DELETE ON production_material_settlement_postings
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- One database gate covers every existing recomputeClosed implementation.
-- For plans without a V150 package, legacy close semantics stay unchanged.
CREATE OR REPLACE FUNCTION fn_guard_production_plan_material_close()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.is_closed = TRUE
       AND COALESCE(OLD.is_closed, FALSE) = FALSE
       AND EXISTS (
           SELECT 1
           FROM production_planning_packages package
           WHERE package.plan_id = NEW.id
             AND package.status = 'CONFIRMED'
             AND package.is_deleted = FALSE
       )
       AND (
           EXISTS (
               SELECT 1
               FROM production_plan_items item
               WHERE item.plan_id = NEW.id
                 AND item.is_deleted = FALSE
                 AND COALESCE(item.iqty, 0) < COALESCE(item.qty, 0)
           )
           OR NOT EXISTS (
               SELECT 1
               FROM v_production_material_clearance clearance
               WHERE clearance.plan_id = NEW.id
           )
           OR EXISTS (
               SELECT 1
               FROM v_production_material_clearance clearance
               WHERE clearance.plan_id = NEW.id
                 AND clearance.can_close = FALSE
           )
       ) THEN
        NEW.is_closed := FALSE;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_plan_material_close
    BEFORE UPDATE OF is_closed ON production_plans
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_plan_material_close();

UPDATE production_plans plan
SET is_closed = FALSE,
    updated_at = now()
WHERE plan.is_closed = TRUE
  AND EXISTS (
      SELECT 1
      FROM production_planning_packages package
      WHERE package.plan_id = plan.id
        AND package.status = 'CONFIRMED'
        AND package.is_deleted = FALSE
  )
  AND (
      EXISTS (
          SELECT 1
          FROM production_plan_items item
          WHERE item.plan_id = plan.id
            AND item.is_deleted = FALSE
            AND COALESCE(item.iqty, 0) < COALESCE(item.qty, 0)
      )
      OR NOT EXISTS (
          SELECT 1 FROM v_production_material_clearance clearance
          WHERE clearance.plan_id = plan.id
      )
      OR EXISTS (
          SELECT 1 FROM v_production_material_clearance clearance
          WHERE clearance.plan_id = plan.id AND clearance.can_close = FALSE
      )
  );

-- A return or issue reversal reduces material still held by production.  It
-- must never reduce that balance below material already confirmed as consumed,
-- approved loss or legal WIP.  This is a database invariant, not a UI rule.
CREATE OR REPLACE FUNCTION fn_guard_production_material_stock_posting()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_event_type text;
    v_event_document uuid;
    v_item_document uuid;
    v_item_upstream uuid;
    v_item_goods uuid;
    v_item_color uuid;
    v_item_unit uuid;
    v_item_rate numeric;
    v_demand_plan uuid;
    v_reservation_demand uuid;
    v_source production_material_stock_postings%ROWTYPE;
    v_source_open numeric;
    v_held numeric;
    v_settled numeric;
BEGIN
    SELECT event_type, stock_document_id
    INTO v_event_type, v_event_document
    FROM production_material_stock_events
    WHERE id = NEW.event_id
    FOR UPDATE;

    SELECT doc_id, upstream_item_id, goods_id, color_id, unit_id, unit_rate
    INTO v_item_document, v_item_upstream, v_item_goods, v_item_color,
         v_item_unit, v_item_rate
    FROM stock_document_items
    WHERE id = NEW.stock_document_item_id;

    SELECT plan_id
    INTO v_demand_plan
    FROM production_material_demands
    WHERE id = NEW.demand_id
      AND is_deleted = FALSE
      AND status NOT IN ('RELEASED', 'REVERSED');
    IF v_demand_plan IS NULL THEN
        RAISE EXCEPTION 'stock posting demand is not active'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_stock_demand_guard';
    END IF;

    PERFORM 1
    FROM production_plans
    WHERE id = v_demand_plan
      AND is_deleted = FALSE
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'stock posting plan is not active'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_stock_demand_guard';
    END IF;

    PERFORM 1
    FROM production_material_demands
    WHERE id = NEW.demand_id
      AND plan_id = v_demand_plan
      AND is_deleted = FALSE
      AND status NOT IN ('RELEASED', 'REVERSED')
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'stock posting demand changed while locking'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_stock_demand_guard';
    END IF;

    SELECT demand_id
    INTO v_reservation_demand
    FROM stock_reservations
    WHERE id = NEW.reservation_id
      AND owner_type = 'PRODUCTION_MATERIAL_DEMAND'
      AND is_deleted = FALSE
    FOR UPDATE;

    IF v_event_type IS DISTINCT FROM NEW.posting_type
       OR v_event_document IS DISTINCT FROM v_item_document
       OR v_reservation_demand IS DISTINCT FROM NEW.demand_id THEN
        RAISE EXCEPTION 'stock posting event, item, demand or reservation mismatch'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'production_material_stock_identity_guard';
    END IF;

    IF NEW.source_posting_id IS NOT NULL THEN
        SELECT * INTO v_source
        FROM production_material_stock_postings
        WHERE id = NEW.source_posting_id
        FOR UPDATE;

        IF NOT FOUND
           OR v_source.demand_id IS DISTINCT FROM NEW.demand_id
           OR v_source.reservation_id IS DISTINCT FROM NEW.reservation_id
           OR (
               NEW.posting_type IN ('ISSUE_REVERSE', 'GOOD_RETURN')
               AND v_source.posting_type <> 'ISSUE'
           )
           OR (
               NEW.posting_type = 'GOOD_RETURN_REVERSE'
               AND v_source.posting_type <> 'GOOD_RETURN'
           )
           OR (
               NEW.posting_type = 'ISSUE_REVERSE'
               AND NEW.stock_document_item_id
                   IS DISTINCT FROM v_source.stock_document_item_id
           )
           OR (
               NEW.posting_type = 'GOOD_RETURN'
               AND v_item_upstream
                   IS DISTINCT FROM v_source.stock_document_item_id
           )
           OR (
               NEW.posting_type = 'GOOD_RETURN'
               AND NOT EXISTS (
                   SELECT 1
                   FROM stock_document_items original
                   WHERE original.id = v_source.stock_document_item_id
                     AND original.goods_id = v_item_goods
                     AND original.color_id IS NOT DISTINCT FROM v_item_color
                     AND original.unit_id IS NOT DISTINCT FROM v_item_unit
                     AND COALESCE(original.unit_rate, 1)
                         = COALESCE(v_item_rate, 1)
               )
           )
           OR (
               NEW.posting_type = 'GOOD_RETURN_REVERSE'
               AND NEW.stock_document_item_id
                   IS DISTINCT FROM v_source.stock_document_item_id
           ) THEN
            RAISE EXCEPTION 'stock posting reversal source is invalid'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_material_stock_source_guard';
        END IF;

        IF NEW.posting_type IN ('ISSUE_REVERSE', 'GOOD_RETURN') THEN
            SELECT v_source.qty_base
                   - COALESCE((
                       SELECT SUM(x.qty_base)
                       FROM production_material_stock_postings x
                       WHERE x.source_posting_id = v_source.id
                         AND x.posting_type = 'ISSUE_REVERSE'
                   ), 0)
                   - COALESCE((
                       SELECT SUM(x.qty_base)
                       FROM production_material_stock_postings x
                       WHERE x.source_posting_id = v_source.id
                         AND x.posting_type = 'GOOD_RETURN'
                   ), 0)
                   + COALESCE((
                       SELECT SUM(rr.qty_base)
                       FROM production_material_stock_postings gr
                       JOIN production_material_stock_postings rr
                         ON rr.source_posting_id = gr.id
                        AND rr.posting_type = 'GOOD_RETURN_REVERSE'
                       WHERE gr.source_posting_id = v_source.id
                         AND gr.posting_type = 'GOOD_RETURN'
                   ), 0)
            INTO v_source_open;
        ELSE
            SELECT v_source.qty_base - COALESCE(SUM(rr.qty_base), 0)
            INTO v_source_open
            FROM production_material_stock_postings rr
            WHERE rr.source_posting_id = v_source.id
              AND rr.posting_type = 'GOOD_RETURN_REVERSE';
        END IF;

        IF NEW.qty_base > v_source_open THEN
            RAISE EXCEPTION 'stock posting reversal exceeds source quantity'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_material_stock_source_capacity_guard';
        END IF;
    END IF;

    IF NEW.posting_type IN ('ISSUE_REVERSE', 'GOOD_RETURN') THEN
        SELECT COALESCE(SUM(CASE posting_type
                   WHEN 'ISSUE' THEN qty_base
                   WHEN 'ISSUE_REVERSE' THEN -qty_base
                   WHEN 'GOOD_RETURN' THEN -qty_base
                   WHEN 'GOOD_RETURN_REVERSE' THEN qty_base
                   ELSE 0 END), 0)
        INTO v_held
        FROM production_material_stock_postings
        WHERE demand_id = NEW.demand_id;

        SELECT COALESCE(SUM(CASE e.event_type
                   WHEN 'POST' THEN p.qty_base ELSE -p.qty_base END), 0)
        INTO v_settled
        FROM production_material_settlement_postings p
        JOIN production_material_settlement_events e ON e.id = p.event_id
        WHERE p.demand_id = NEW.demand_id;

        IF v_held - NEW.qty_base < v_settled THEN
            RAISE EXCEPTION 'return or reversal exceeds unsettled material'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'production_material_stock_clearance_guard';
        END IF;
    END IF;

    IF NEW.posting_type IN ('ISSUE', 'GOOD_RETURN_REVERSE') THEN
        UPDATE production_plans
        SET is_closed = FALSE,
            updated_at = now()
        WHERE id = v_demand_plan
          AND is_closed = TRUE;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_material_stock_posting
    BEFORE INSERT ON production_material_stock_postings
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_material_stock_posting();
