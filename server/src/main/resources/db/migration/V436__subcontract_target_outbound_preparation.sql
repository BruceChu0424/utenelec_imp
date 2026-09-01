-- V436: subcontract target-item outbound and explicit make-before-outbound preparation.
--
-- V304 remains immutable history.  Its rows mean "send BOM components to the
-- subcontractor" and are retained as LEGACY_BOM_COMPONENT.  New approved order
-- lines always ship the ordered target item itself:
--   DIRECT_OUTBOUND   - no active child BOM; warehouse chooses the source
--                       warehouse and reserves qualified free stock.
--   MAKE_THEN_OUTBOUND - active child BOM; planning runs the normal MAKE chain,
--                       and only a fully accepted finished-in quantity can make
--                       the target item available for subcontract outbound.

ALTER TABLE production_material_analysis_items
    DROP CONSTRAINT production_material_analysis_item_source_type_chk,
    ADD CONSTRAINT production_material_analysis_item_source_type_chk CHECK (
        source_type IN (
            'SALES_ORDER_ITEM', 'REWORK', 'TRIAL', 'SAMPLE',
            'STOCK', 'OTHER', 'MAKE_COMPONENT',
            'SUBCONTRACT_PREPARATION'
        )
    );

ALTER TABLE subcontract_material_plan_items
    ADD COLUMN flow_mode TEXT NOT NULL DEFAULT 'LEGACY_BOM_COMPONENT',
    ADD COLUMN preparation_status TEXT NOT NULL DEFAULT 'LEGACY_READY',
    ADD COLUMN prepared_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN bom_has_children_snapshot BOOLEAN,
    ADD COLUMN preparation_bom_fingerprint TEXT,
    ADD COLUMN preparation_warehouse_id UUID
        REFERENCES warehouses(id) ON DELETE RESTRICT,
    ADD COLUMN preparation_analysis_id UUID
        REFERENCES production_material_analyses(id) ON DELETE RESTRICT,
    ADD COLUMN preparation_analysis_item_id UUID
        REFERENCES production_material_analysis_items(id) ON DELETE RESTRICT,
    ADD COLUMN preparation_started_by UUID
        REFERENCES users(id) ON DELETE RESTRICT,
    ADD COLUMN preparation_started_at TIMESTAMPTZ,
    ADD COLUMN preparation_version BIGINT NOT NULL DEFAULT 0;

-- Existing V304 rows remain executable under their frozen component/BOM
-- semantics.  No historical issue, receipt or supplier ledger is rewritten.
UPDATE subcontract_material_plan_items
SET prepared_qty = planned_qty
WHERE flow_mode = 'LEGACY_BOM_COMPONENT';

-- Pre-V436 rows are LEGACY. The only new DIRECT/MAKE INSERT path writes both
-- snapshot values, and START/draft-save recompute the same canonical hash.
ALTER TABLE subcontract_material_plan_items
    ADD CONSTRAINT subcontract_material_plan_item_bom_snapshot_chk CHECK (
        (flow_mode = 'LEGACY_BOM_COMPONENT'
            AND bom_has_children_snapshot IS NULL
            AND preparation_bom_fingerprint IS NULL)
        OR
        (flow_mode = 'DIRECT_OUTBOUND'
            AND bom_has_children_snapshot = FALSE
            AND preparation_bom_fingerprint ~ '^[0-9a-f]{64}$')
        OR
        (flow_mode = 'MAKE_THEN_OUTBOUND'
            AND bom_has_children_snapshot = TRUE
            AND preparation_bom_fingerprint ~ '^[0-9a-f]{64}$')
    ) NOT VALID;

ALTER TABLE subcontract_material_plan_items
    ADD CONSTRAINT subcontract_material_plan_item_flow_mode_chk CHECK (
        flow_mode IN (
            'LEGACY_BOM_COMPONENT',
            'DIRECT_OUTBOUND',
            'MAKE_THEN_OUTBOUND'
        )
    ),
    ADD CONSTRAINT subcontract_material_plan_item_preparation_status_chk CHECK (
        preparation_status IN (
            'LEGACY_READY',
            'ACTION_REQUIRED',
            'IN_PREPARATION',
            'WAITING_FQC',
            'WAITING_INBOUND',
            'READY_OUTBOUND',
            'OUTBOUND_COMPLETE',
            'CANCELLED'
        )
    ),
    ADD CONSTRAINT subcontract_material_plan_item_prepared_qty_chk CHECK (
        prepared_qty >= 0 AND prepared_qty <= planned_qty
    ),
    ADD CONSTRAINT subcontract_material_plan_item_preparation_version_chk CHECK (
        preparation_version >= 0
    ),
    ADD CONSTRAINT subcontract_material_plan_item_preparation_shape_chk CHECK (
        (
            flow_mode = 'LEGACY_BOM_COMPONENT'
            AND preparation_status IN ('LEGACY_READY', 'CANCELLED')
            AND preparation_analysis_id IS NULL
            AND preparation_analysis_item_id IS NULL
            AND preparation_started_by IS NULL
            AND preparation_started_at IS NULL
        )
        OR
        (
            flow_mode = 'DIRECT_OUTBOUND'
            AND preparation_status IN (
                'READY_OUTBOUND', 'OUTBOUND_COMPLETE', 'CANCELLED'
            )
            AND prepared_qty = planned_qty
            AND preparation_analysis_id IS NULL
            AND preparation_analysis_item_id IS NULL
            AND preparation_started_by IS NULL
            AND preparation_started_at IS NULL
        )
        OR
        (
            flow_mode = 'MAKE_THEN_OUTBOUND'
            AND (
                (
                    preparation_status = 'ACTION_REQUIRED'
                    AND preparation_analysis_id IS NULL
                    AND preparation_analysis_item_id IS NULL
                    AND preparation_started_by IS NULL
                    AND preparation_started_at IS NULL
                    AND prepared_qty = 0
                )
                OR
                (
                    preparation_status IN (
                        'IN_PREPARATION', 'WAITING_FQC', 'WAITING_INBOUND',
                        'READY_OUTBOUND', 'OUTBOUND_COMPLETE'
                    )
                    AND preparation_warehouse_id IS NOT NULL
                    AND preparation_analysis_id IS NOT NULL
                    AND preparation_analysis_item_id IS NOT NULL
                    AND preparation_started_by IS NOT NULL
                    AND preparation_started_at IS NOT NULL
                )
                OR preparation_status = 'CANCELLED'
            )
        )
    );

ALTER TABLE subcontract_material_plan_items
    ADD CONSTRAINT subcontract_material_plan_item_preparation_source_fk
    FOREIGN KEY (preparation_analysis_id, preparation_analysis_item_id)
    REFERENCES production_material_analysis_items(analysis_id, id)
    ON DELETE RESTRICT
    DEFERRABLE INITIALLY DEFERRED;

CREATE OR REPLACE FUNCTION fn_assert_subcontract_preparation_source(
    p_plan_item_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM subcontract_material_plan_items plan_item
        WHERE plan_item.id = p_plan_item_id
          AND plan_item.flow_mode = 'MAKE_THEN_OUTBOUND'
          AND plan_item.preparation_analysis_id IS NOT NULL
          AND NOT EXISTS (
              SELECT 1
              FROM production_material_analysis_items analysis_item
              WHERE analysis_item.analysis_id = plan_item.preparation_analysis_id
                AND analysis_item.id = plan_item.preparation_analysis_item_id
                AND analysis_item.is_deleted = FALSE
                AND analysis_item.source_type = 'SUBCONTRACT_PREPARATION'
                AND analysis_item.source_ref =
                    'SC-PREP:' || plan_item.order_item_id::text
                AND analysis_item.goods_id = plan_item.goods_id
                AND analysis_item.color_id IS NOT DISTINCT FROM plan_item.color_id
                AND analysis_item.unit_id = plan_item.unit_id
                AND analysis_item.requested_qty = plan_item.planned_qty
          )
    ) THEN
        RAISE EXCEPTION
            'subcontract preparation analysis lineage is inconsistent'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'subcontract_preparation_analysis_lineage_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_check_subcontract_preparation_source()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        PERFORM fn_assert_subcontract_preparation_source(OLD.id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        PERFORM fn_assert_subcontract_preparation_source(NEW.id);
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_subcontract_preparation_source_guard
    AFTER INSERT OR UPDATE OR DELETE ON subcontract_material_plan_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_preparation_source();

CREATE OR REPLACE FUNCTION fn_check_subcontract_preparation_analysis_source()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_plan_item_id UUID;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        FOR v_plan_item_id IN
            SELECT id
            FROM subcontract_material_plan_items
            WHERE preparation_analysis_id = OLD.analysis_id
              AND preparation_analysis_item_id = OLD.id
        LOOP
            PERFORM fn_assert_subcontract_preparation_source(v_plan_item_id);
        END LOOP;
    END IF;
    IF TG_OP <> 'DELETE' THEN
        FOR v_plan_item_id IN
            SELECT id
            FROM subcontract_material_plan_items
            WHERE preparation_analysis_id = NEW.analysis_id
              AND preparation_analysis_item_id = NEW.id
        LOOP
            PERFORM fn_assert_subcontract_preparation_source(v_plan_item_id);
        END LOOP;
        IF NEW.source_type = 'SUBCONTRACT_PREPARATION'
           AND NOT EXISTS (
               SELECT 1
               FROM subcontract_material_plan_items plan_item
               WHERE plan_item.preparation_analysis_id = NEW.analysis_id
                 AND plan_item.preparation_analysis_item_id = NEW.id
                 AND plan_item.flow_mode = 'MAKE_THEN_OUTBOUND'
                 AND plan_item.is_deleted = FALSE
                 AND NEW.source_ref =
                     'SC-PREP:' || plan_item.order_item_id::text
           ) THEN
            RAISE EXCEPTION
                'SUBCONTRACT_PREPARATION analysis item lacks a real subcontract task'
                USING ERRCODE = '23514',
                      CONSTRAINT = 'subcontract_preparation_task_source_guard';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_subcontract_preparation_analysis_source_guard
    AFTER INSERT OR UPDATE OR DELETE ON production_material_analysis_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_subcontract_preparation_analysis_source();

CREATE INDEX idx_subcontract_material_plan_items_preparation_tasks
    ON subcontract_material_plan_items(
        preparation_status, updated_at, id
    )
    WHERE is_deleted = FALSE
      AND flow_mode = 'MAKE_THEN_OUTBOUND'
      AND preparation_status NOT IN ('OUTBOUND_COMPLETE', 'CANCELLED');

CREATE INDEX idx_subcontract_material_plan_items_preparation_analysis
    ON subcontract_material_plan_items(preparation_analysis_item_id)
    WHERE preparation_analysis_item_id IS NOT NULL;

COMMENT ON COLUMN subcontract_material_plan_items.flow_mode IS
    'V436 flow: legacy BOM-component issue, direct target outbound, or MAKE target then outbound';
COMMENT ON COLUMN subcontract_material_plan_items.prepared_qty IS
    'Target-item quantity in goods base units dedicated to this order line; MAKE quantity comes only from accepted FINISHED_IN';
COMMENT ON COLUMN subcontract_material_plan_items.preparation_bom_fingerprint IS
    'SHA-256 of ordered active direct BOM edge UUID/component/color/qty snapshot; START/save fails if current structure drifted';

-- Stable, replayable planning command.  The task row remains the authority;
-- the notice is only a reminder to open this task.
CREATE TABLE subcontract_outbound_preparation_commands (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_item_id UUID NOT NULL
        REFERENCES subcontract_material_plan_items(id) ON DELETE RESTRICT,
    operation TEXT NOT NULL CHECK (operation IN ('START_PREPARATION')),
    idempotency_key TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    expected_version BIGINT NOT NULL,
    resulting_version BIGINT NOT NULL,
    analysis_id UUID
        REFERENCES production_material_analyses(id) ON DELETE RESTRICT,
    analysis_item_id UUID
        REFERENCES production_material_analysis_items(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT subcontract_outbound_preparation_command_key_chk CHECK (
        length(btrim(idempotency_key)) BETWEEN 8 AND 128
        AND request_hash ~ '^[0-9a-f]{64}$'
        AND expected_version >= 0
        AND resulting_version = expected_version + 1
    ),
    UNIQUE (plan_item_id, operation, idempotency_key)
);

-- Extend the single stock-reservation authority.  These reservations are
-- visible to v_stock_available, so another analysis/order cannot spend a
-- target item that is already dedicated to subcontract outbound.
ALTER TABLE stock_reservations
    DROP CONSTRAINT stock_reservations_owner_type_chk,
    DROP CONSTRAINT stock_reservations_purpose_chk,
    DROP CONSTRAINT stock_reservations_owner_shape_chk;

ALTER TABLE stock_reservations
    ADD CONSTRAINT stock_reservations_owner_type_chk CHECK (
        owner_type IN (
            'SALES_ORDER_ITEM', 'PRODUCTION_MATERIAL_DEMAND',
            'PREPLAN_ANALYSIS', 'SUBCONTRACT_OUTBOUND'
        )
    ),
    ADD CONSTRAINT stock_reservations_purpose_chk CHECK (
        purpose IN (
            'SALES_FULFILLMENT', 'PRODUCTION_MATERIAL',
            'PREPLAN_MATERIAL', 'SUBCONTRACT_OUTBOUND'
        )
    ),
    ADD CONSTRAINT stock_reservations_owner_shape_chk CHECK (
        (
            owner_type = 'SALES_ORDER_ITEM'
            AND purpose = 'SALES_FULFILLMENT'
            AND order_item_id IS NOT NULL
            AND owner_id = order_item_id
            AND demand_id IS NULL
        )
        OR
        (
            owner_type = 'PRODUCTION_MATERIAL_DEMAND'
            AND purpose = 'PRODUCTION_MATERIAL'
            AND order_item_id IS NULL
            AND demand_id IS NOT NULL
            AND owner_id = demand_id
            AND warehouse_id IS NOT NULL
            AND supply_type = 'STOCK_BALANCE'
            AND supply_id IS NOT NULL
            AND idempotency_key IS NOT NULL
        )
        OR
        (
            owner_type = 'PREPLAN_ANALYSIS'
            AND purpose = 'PREPLAN_MATERIAL'
            AND order_item_id IS NULL
            AND demand_id IS NULL
            AND owner_id IS NOT NULL
            AND warehouse_id IS NOT NULL
            AND supply_type IN (
                'PURCHASE_REQUEST_ITEM',
                'SUBCONTRACT_APPLICATION_ITEM',
                'PRODUCTION_PLAN_ITEM',
                'MATERIAL_REALLOCATION_PRIORITY'
            )
            AND supply_id IS NOT NULL
            AND idempotency_key IS NOT NULL
        )
        OR
        (
            owner_type = 'SUBCONTRACT_OUTBOUND'
            AND purpose = 'SUBCONTRACT_OUTBOUND'
            AND order_item_id IS NULL
            AND demand_id IS NULL
            AND owner_id IS NOT NULL
            AND warehouse_id IS NOT NULL
            AND supply_type IN ('STOCK_BALANCE', 'PRODUCTION_FINISHED_IN')
            AND supply_id IS NOT NULL
            AND idempotency_key IS NOT NULL
        )
    );

CREATE INDEX idx_stock_reservation_subcontract_outbound_owner
    ON stock_reservations(owner_id, warehouse_id, goods_id, color_id, status)
    WHERE is_deleted = FALSE
      AND owner_type = 'SUBCONTRACT_OUTBOUND';

CREATE INDEX idx_stock_reservation_subcontract_outbound_supply
    ON stock_reservations(supply_type, supply_id)
    WHERE is_deleted = FALSE
      AND owner_type = 'SUBCONTRACT_OUTBOUND';

-- Exact proof that an issue consumed only reservations owned by its own target
-- plan item.  Reversal retains the row and changes EFFECTIVE -> REVERSED.
CREATE TABLE subcontract_outbound_issue_reservation_allocations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    issue_id UUID NOT NULL
        REFERENCES subcontract_material_issues(id) ON DELETE RESTRICT,
    issue_item_id UUID NOT NULL
        REFERENCES subcontract_material_issue_items(id) ON DELETE RESTRICT,
    plan_item_id UUID NOT NULL
        REFERENCES subcontract_material_plan_items(id) ON DELETE RESTRICT,
    reservation_id UUID NOT NULL
        REFERENCES stock_reservations(id) ON DELETE RESTRICT,
    allocated_qty NUMERIC(18,4) NOT NULL CHECK (allocated_qty > 0),
    status TEXT NOT NULL DEFAULT 'EFFECTIVE'
        CHECK (status IN ('EFFECTIVE', 'REVERSED')),
    idempotency_key TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    reversed_at TIMESTAMPTZ,
    reversed_by UUID REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT subcontract_outbound_issue_reservation_status_chk CHECK (
        (status = 'EFFECTIVE' AND reversed_at IS NULL AND reversed_by IS NULL)
        OR
        (status = 'REVERSED' AND reversed_at IS NOT NULL AND reversed_by IS NOT NULL)
    ),
    CONSTRAINT subcontract_outbound_issue_reservation_key_chk CHECK (
        length(btrim(idempotency_key)) BETWEEN 8 AND 128
    ),
    UNIQUE (issue_item_id, reservation_id),
    UNIQUE (idempotency_key)
);

CREATE INDEX idx_subcontract_outbound_issue_reservation_plan
    ON subcontract_outbound_issue_reservation_allocations(plan_item_id, status);

CREATE OR REPLACE FUNCTION fn_assert_subcontract_outbound_issue_allocation(
    p_issue_item_id UUID
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_expected NUMERIC;
    v_allocated NUMERIC;
BEGIN
    SELECT CASE WHEN issue.status = 1 AND NOT issue.is_deleted
                     AND NOT issue_item.is_deleted
                THEN issue_item.qty ELSE 0 END
      INTO v_expected
    FROM subcontract_material_issue_items issue_item
    JOIN subcontract_material_issues issue ON issue.id = issue_item.issue_id
    JOIN subcontract_material_plan_items plan_item
      ON plan_item.id = issue_item.plan_item_id
     AND plan_item.flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND')
    WHERE issue_item.id = p_issue_item_id;
    IF NOT FOUND THEN RETURN; END IF;

    IF EXISTS (
        SELECT 1
        FROM subcontract_outbound_issue_reservation_allocations allocation
        JOIN subcontract_material_issue_items issue_item
          ON issue_item.id = allocation.issue_item_id
        JOIN subcontract_material_issues issue ON issue.id = issue_item.issue_id
        JOIN subcontract_material_plan_items plan_item
          ON plan_item.id = issue_item.plan_item_id
        JOIN stock_reservations reservation
          ON reservation.id = allocation.reservation_id
        WHERE allocation.issue_item_id = p_issue_item_id
          AND allocation.status = 'EFFECTIVE'
          AND (allocation.issue_id <> issue_item.issue_id
            OR allocation.plan_item_id <> issue_item.plan_item_id
            OR reservation.owner_type <> 'SUBCONTRACT_OUTBOUND'
            OR reservation.purpose <> 'SUBCONTRACT_OUTBOUND'
            OR reservation.owner_id <> allocation.plan_item_id
            OR reservation.warehouse_id IS DISTINCT FROM issue.warehouse_id
            OR reservation.goods_id IS DISTINCT FROM issue_item.goods_id
            OR reservation.color_id IS DISTINCT FROM issue_item.color_id
            OR plan_item.goods_id IS DISTINCT FROM issue_item.goods_id
            OR plan_item.color_id IS DISTINCT FROM issue_item.color_id)
    ) THEN
        RAISE EXCEPTION 'subcontract outbound allocation provenance is inconsistent'
            USING ERRCODE = '23514';
    END IF;

    SELECT COALESCE(SUM(allocated_qty),0) INTO v_allocated
    FROM subcontract_outbound_issue_reservation_allocations
    WHERE issue_item_id = p_issue_item_id AND status = 'EFFECTIVE';
    IF v_allocated <> v_expected THEN
        RAISE EXCEPTION 'approved subcontract target issue lacks exact reservation coverage'
            USING ERRCODE = '23514';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_subcontract_outbound_reservation_allocation(
    p_reservation_id UUID
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_consumed NUMERIC;
    v_allocated NUMERIC;
BEGIN
    SELECT consumed_qty INTO v_consumed FROM stock_reservations
    WHERE id = p_reservation_id AND owner_type = 'SUBCONTRACT_OUTBOUND';
    IF NOT FOUND THEN RETURN; END IF;
    SELECT COALESCE(SUM(allocated_qty),0) INTO v_allocated
    FROM subcontract_outbound_issue_reservation_allocations
    WHERE reservation_id = p_reservation_id AND status = 'EFFECTIVE';
    IF v_allocated <> v_consumed THEN
        RAISE EXCEPTION 'subcontract outbound reservation lacks exact issue allocation'
            USING ERRCODE = '23514';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_assert_subcontract_preparation_finished_source(
    p_reservation_id UUID
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM stock_reservations reservation
        WHERE reservation.id = p_reservation_id
          AND reservation.owner_type = 'SUBCONTRACT_OUTBOUND'
          AND reservation.supply_type = 'PRODUCTION_FINISHED_IN'
          AND (reservation.qty - reservation.consumed_qty
               - reservation.released_qty > 0
               OR reservation.consumed_qty > 0)
    ) AND NOT EXISTS (
        SELECT 1
        FROM stock_reservations reservation
        JOIN subcontract_material_plan_items plan_item
          ON plan_item.id = reservation.owner_id
         AND plan_item.flow_mode = 'MAKE_THEN_OUTBOUND'
         AND plan_item.is_deleted = FALSE
        JOIN stock_document_items stock_item
          ON stock_item.id = reservation.supply_id
         AND stock_item.doc_id = reservation.source_doc_id
         AND stock_item.bill_type = 'FINISHED_IN'
         AND stock_item.is_deleted = FALSE
        JOIN stock_documents stock_doc
          ON stock_doc.id = stock_item.doc_id
         AND stock_doc.doc_type = 'FINISHED_IN'
         AND stock_doc.status = 1
         AND stock_doc.is_deleted = FALSE
        JOIN production_plan_items production_item
          ON production_item.id = stock_item.upstream_item_id
         AND production_item.is_deleted = FALSE
        JOIN production_plans production_plan
          ON production_plan.id = production_item.plan_id
         AND production_plan.status = 1
         AND production_plan.is_deleted = FALSE
        JOIN production_material_analysis_plan_links analysis_link
          ON analysis_link.plan_id = production_plan.id
         AND analysis_link.analysis_id = plan_item.preparation_analysis_id
         AND analysis_link.analysis_item_id = plan_item.preparation_analysis_item_id
         AND analysis_link.allocation_status = 'APPROVED'
        WHERE reservation.id = p_reservation_id
          AND reservation.purpose = 'SUBCONTRACT_OUTBOUND'
          AND reservation.source_doc_type = 'PRODUCTION_INBOUND'
          AND reservation.warehouse_id = stock_doc.warehouse_id
          AND reservation.warehouse_id = plan_item.preparation_warehouse_id
          AND reservation.goods_id = stock_item.goods_id
          AND reservation.goods_id = production_item.goods_id
          AND reservation.goods_id = plan_item.goods_id
          AND reservation.color_id IS NOT DISTINCT FROM stock_item.color_id
          AND reservation.color_id IS NOT DISTINCT FROM production_item.color_id
          AND reservation.color_id IS NOT DISTINCT FROM plan_item.color_id
          AND stock_item.unit_id = production_item.unit_id
          AND stock_item.unit_id = plan_item.unit_id
          AND COALESCE(stock_item.unit_rate, 1) = 1
          AND COALESCE(production_item.unit_rate, 1) = 1
          AND reservation.qty = stock_item.qty * COALESCE(stock_item.unit_rate, 1)
          AND production_plan.material_analysis_id = plan_item.preparation_analysis_id
          AND production_plan.material_analysis_item_id =
              plan_item.preparation_analysis_item_id
    ) THEN
        RAISE EXCEPTION 'subcontract preparation FINISHED_IN reservation lineage is inconsistent'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'subcontract_preparation_finished_source_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_check_subcontract_outbound_allocation()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        PERFORM fn_assert_subcontract_outbound_issue_allocation(OLD.issue_item_id);
        PERFORM fn_assert_subcontract_outbound_reservation_allocation(OLD.reservation_id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        PERFORM fn_assert_subcontract_outbound_issue_allocation(NEW.issue_item_id);
        PERFORM fn_assert_subcontract_outbound_reservation_allocation(NEW.reservation_id);
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_subcontract_outbound_allocation_guard
    AFTER INSERT OR UPDATE OR DELETE
    ON subcontract_outbound_issue_reservation_allocations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_outbound_allocation();

CREATE OR REPLACE FUNCTION fn_check_subcontract_outbound_reservation()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP <> 'INSERT' AND OLD.owner_type = 'SUBCONTRACT_OUTBOUND' THEN
        PERFORM fn_assert_subcontract_outbound_reservation_allocation(OLD.id);
        PERFORM fn_assert_subcontract_preparation_finished_source(OLD.id);
    END IF;
    IF TG_OP <> 'DELETE' AND NEW.owner_type = 'SUBCONTRACT_OUTBOUND' THEN
        PERFORM fn_assert_subcontract_outbound_reservation_allocation(NEW.id);
        PERFORM fn_assert_subcontract_preparation_finished_source(NEW.id);
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_subcontract_outbound_reservation_guard
    AFTER INSERT OR UPDATE OR DELETE ON stock_reservations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_outbound_reservation();

CREATE OR REPLACE FUNCTION fn_recheck_subcontract_preparation_finished_source(
    p_kind TEXT, p_id UUID
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_reservation_id UUID;
BEGIN
    IF p_id IS NULL THEN RETURN; END IF;
    FOR v_reservation_id IN
        SELECT reservation.id
        FROM stock_reservations reservation
        WHERE reservation.owner_type = 'SUBCONTRACT_OUTBOUND'
          AND reservation.supply_type = 'PRODUCTION_FINISHED_IN'
          AND (
              (p_kind = 'STOCK_ITEM' AND reservation.supply_id = p_id)
              OR (p_kind = 'STOCK_DOC' AND reservation.source_doc_id = p_id)
              OR (p_kind = 'PLAN_ITEM' AND reservation.owner_id = p_id)
              OR (p_kind = 'PRODUCTION_ITEM' AND EXISTS (
                  SELECT 1 FROM stock_document_items stock_item
                  WHERE stock_item.id = reservation.supply_id
                    AND stock_item.upstream_item_id = p_id))
              OR (p_kind IN ('PRODUCTION_PLAN','ANALYSIS_LINK') AND EXISTS (
                  SELECT 1
                  FROM stock_document_items stock_item
                  JOIN production_plan_items production_item
                    ON production_item.id = stock_item.upstream_item_id
                  WHERE stock_item.id = reservation.supply_id
                    AND production_item.plan_id = p_id))
          )
    LOOP
        PERFORM fn_assert_subcontract_preparation_finished_source(v_reservation_id);
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION fn_check_subcontract_preparation_finished_source()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_kind TEXT;
BEGIN
    v_kind := CASE TG_TABLE_NAME
        WHEN 'stock_document_items' THEN 'STOCK_ITEM'
        WHEN 'stock_documents' THEN 'STOCK_DOC'
        WHEN 'production_plan_items' THEN 'PRODUCTION_ITEM'
        WHEN 'production_plans' THEN 'PRODUCTION_PLAN'
        WHEN 'production_material_analysis_plan_links' THEN 'ANALYSIS_LINK'
        ELSE 'PLAN_ITEM'
    END;
    IF TG_OP <> 'INSERT' THEN
        PERFORM fn_recheck_subcontract_preparation_finished_source(
            v_kind,
            CASE WHEN v_kind = 'ANALYSIS_LINK'
                 THEN NULLIF(to_jsonb(OLD) ->> 'plan_id', '')::UUID
                 ELSE OLD.id END);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        PERFORM fn_recheck_subcontract_preparation_finished_source(
            v_kind,
            CASE WHEN v_kind = 'ANALYSIS_LINK'
                 THEN NULLIF(to_jsonb(NEW) ->> 'plan_id', '')::UUID
                 ELSE NEW.id END);
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_subcontract_prep_finished_stock_item_guard
    AFTER INSERT OR UPDATE OR DELETE ON stock_document_items
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_check_subcontract_preparation_finished_source();
CREATE CONSTRAINT TRIGGER trg_subcontract_prep_finished_stock_doc_guard
    AFTER INSERT OR UPDATE OR DELETE ON stock_documents
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_check_subcontract_preparation_finished_source();
CREATE CONSTRAINT TRIGGER trg_subcontract_prep_finished_production_item_guard
    AFTER INSERT OR UPDATE OR DELETE ON production_plan_items
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_check_subcontract_preparation_finished_source();
CREATE CONSTRAINT TRIGGER trg_subcontract_prep_finished_production_plan_guard
    AFTER INSERT OR UPDATE OR DELETE ON production_plans
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_check_subcontract_preparation_finished_source();
CREATE CONSTRAINT TRIGGER trg_subcontract_prep_finished_analysis_link_guard
    AFTER INSERT OR UPDATE OR DELETE ON production_material_analysis_plan_links
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_check_subcontract_preparation_finished_source();
CREATE CONSTRAINT TRIGGER trg_subcontract_prep_finished_plan_item_guard
    AFTER INSERT OR UPDATE OR DELETE ON subcontract_material_plan_items
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_check_subcontract_preparation_finished_source();

CREATE OR REPLACE FUNCTION fn_check_subcontract_outbound_issue_source()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_item_id UUID;
BEGIN
    IF TG_TABLE_NAME = 'subcontract_material_issue_items' THEN
        IF TG_OP <> 'INSERT' THEN
            PERFORM fn_assert_subcontract_outbound_issue_allocation(OLD.id);
        END IF;
        IF TG_OP <> 'DELETE' THEN
            PERFORM fn_assert_subcontract_outbound_issue_allocation(NEW.id);
        END IF;
        RETURN NULL;
    END IF;
    IF TG_OP <> 'INSERT' THEN
        FOR v_item_id IN SELECT id FROM subcontract_material_issue_items WHERE issue_id = OLD.id LOOP
            PERFORM fn_assert_subcontract_outbound_issue_allocation(v_item_id);
        END LOOP;
    END IF;
    IF TG_OP <> 'DELETE' THEN
        FOR v_item_id IN SELECT id FROM subcontract_material_issue_items WHERE issue_id = NEW.id LOOP
            PERFORM fn_assert_subcontract_outbound_issue_allocation(v_item_id);
        END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_subcontract_outbound_issue_item_allocation_guard
    AFTER INSERT OR UPDATE OR DELETE ON subcontract_material_issue_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_outbound_issue_source();
CREATE CONSTRAINT TRIGGER trg_subcontract_outbound_issue_header_allocation_guard
    AFTER INSERT OR UPDATE OR DELETE ON subcontract_material_issues
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_outbound_issue_source();

-- New-flow receipt must be physically outbound first.  It must also be backed
-- by the V221 supplier-held ledger consumption; changing only a receipt header
-- or only consumed_qty through direct SQL therefore fails at commit.
CREATE OR REPLACE FUNCTION fn_assert_subcontract_target_outbound_receipt(
    p_order_item_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_is_new_flow BOOLEAN;
    v_issued NUMERIC;
    v_received NUMERIC;
    v_consumed NUMERIC;
BEGIN
    IF p_order_item_id IS NULL THEN
        RETURN;
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM subcontract_material_plan_items plan_item
        WHERE plan_item.order_item_id = p_order_item_id
          AND plan_item.is_deleted = FALSE
          AND plan_item.flow_mode IN ('DIRECT_OUTBOUND', 'MAKE_THEN_OUTBOUND')
    ) INTO v_is_new_flow;

    IF NOT v_is_new_flow THEN
        RETURN;
    END IF;

    SELECT COALESCE(SUM(issue_item.qty * COALESCE(issue_item.unit_rate, 1)), 0),
           COALESCE(SUM(issue_item.consumed_qty), 0)
      INTO v_issued, v_consumed
    FROM subcontract_material_issue_items issue_item
    JOIN subcontract_material_issues issue
      ON issue.id = issue_item.issue_id
     AND issue.status = 1
     AND issue.is_deleted = FALSE
    JOIN subcontract_material_plan_items plan_item
      ON plan_item.id = issue_item.plan_item_id
     AND plan_item.flow_mode IN ('DIRECT_OUTBOUND', 'MAKE_THEN_OUTBOUND')
    WHERE issue_item.order_item_id = p_order_item_id
      AND issue_item.is_deleted = FALSE;

    SELECT COALESCE(SUM(receipt_item.qty * COALESCE(receipt_item.unit_rate, 1)), 0)
      INTO v_received
    FROM subcontract_receipt_items receipt_item
    JOIN subcontract_receipts receipt
      ON receipt.id = receipt_item.receipt_id
     AND receipt.status = 1
     AND receipt.is_deleted = FALSE
    WHERE receipt_item.order_item_id = p_order_item_id
      AND receipt_item.is_deleted = FALSE;

    IF v_received > v_issued THEN
        RAISE EXCEPTION
            'subcontract target receipt exceeds approved target-item outbound'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'subcontract_target_outbound_first_guard';
    END IF;
    IF v_consumed <> v_received THEN
        RAISE EXCEPTION
            'subcontract target receipt lacks exact supplier-held consumption'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'subcontract_target_outbound_consumption_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_check_subcontract_target_outbound_receipt()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_order_item UUID;
    v_new_order_item UUID;
BEGIN
    IF TG_TABLE_NAME = 'subcontract_receipt_items' THEN
        IF TG_OP <> 'INSERT' THEN
            v_old_order_item := OLD.order_item_id;
        END IF;
        IF TG_OP <> 'DELETE' THEN
            v_new_order_item := NEW.order_item_id;
        END IF;
    ELSIF TG_TABLE_NAME = 'subcontract_material_issue_items' THEN
        IF TG_OP <> 'INSERT' THEN
            v_old_order_item := OLD.order_item_id;
        END IF;
        IF TG_OP <> 'DELETE' THEN
            v_new_order_item := NEW.order_item_id;
        END IF;
    ELSE
        IF TG_OP <> 'INSERT' THEN
            FOR v_old_order_item IN
                SELECT DISTINCT order_item_id
                FROM subcontract_receipt_items
                WHERE receipt_id = OLD.id AND order_item_id IS NOT NULL
            LOOP
                PERFORM fn_assert_subcontract_target_outbound_receipt(v_old_order_item);
            END LOOP;
        END IF;
        IF TG_OP <> 'DELETE' THEN
            FOR v_new_order_item IN
                SELECT DISTINCT order_item_id
                FROM subcontract_receipt_items
                WHERE receipt_id = NEW.id AND order_item_id IS NOT NULL
            LOOP
                PERFORM fn_assert_subcontract_target_outbound_receipt(v_new_order_item);
            END LOOP;
        END IF;
        RETURN NULL;
    END IF;

    IF v_old_order_item IS NOT NULL THEN
        PERFORM fn_assert_subcontract_target_outbound_receipt(v_old_order_item);
    END IF;
    IF v_new_order_item IS NOT NULL
       AND v_new_order_item IS DISTINCT FROM v_old_order_item THEN
        PERFORM fn_assert_subcontract_target_outbound_receipt(v_new_order_item);
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_subcontract_target_receipt_header_guard
    AFTER INSERT OR UPDATE OR DELETE ON subcontract_receipts
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_target_outbound_receipt();

CREATE CONSTRAINT TRIGGER trg_subcontract_target_receipt_item_guard
    AFTER INSERT OR UPDATE OR DELETE ON subcontract_receipt_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_target_outbound_receipt();

CREATE CONSTRAINT TRIGGER trg_subcontract_target_issue_consumption_guard
    AFTER INSERT OR UPDATE OR DELETE ON subcontract_material_issue_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_target_outbound_receipt();

CREATE OR REPLACE FUNCTION fn_check_subcontract_target_issue_header()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_order_item UUID;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        FOR v_order_item IN
            SELECT DISTINCT order_item_id
            FROM subcontract_material_issue_items
            WHERE issue_id = OLD.id AND order_item_id IS NOT NULL
        LOOP
            PERFORM fn_assert_subcontract_target_outbound_receipt(v_order_item);
        END LOOP;
    END IF;
    IF TG_OP <> 'DELETE' THEN
        FOR v_order_item IN
            SELECT DISTINCT order_item_id
            FROM subcontract_material_issue_items
            WHERE issue_id = NEW.id AND order_item_id IS NOT NULL
        LOOP
            PERFORM fn_assert_subcontract_target_outbound_receipt(v_order_item);
        END LOOP;
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_subcontract_target_issue_header_guard
    AFTER INSERT OR UPDATE OR DELETE ON subcontract_material_issues
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_target_issue_header();

CREATE OR REPLACE FUNCTION fn_guard_subcontract_preparation_command_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'subcontract preparation commands are append-only'
        USING ERRCODE = '23514';
END;
$$;

CREATE TRIGGER trg_subcontract_preparation_command_append_only
    BEFORE UPDATE OR DELETE ON subcontract_outbound_preparation_commands
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_subcontract_preparation_command_append_only();

CREATE TRIGGER trg_audit_subcontract_outbound_preparation_commands
    AFTER INSERT OR UPDATE OR DELETE
    ON subcontract_outbound_preparation_commands
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE TRIGGER trg_audit_subcontract_outbound_issue_reservation_allocations
    AFTER INSERT OR UPDATE OR DELETE
    ON subcontract_outbound_issue_reservation_allocations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE subcontract_outbound_preparation_commands IS
    'Replayable planner-owned START_PREPARATION commands for make-before-subcontract tasks';
COMMENT ON TABLE subcontract_outbound_issue_reservation_allocations IS
    'Exact reservation slices consumed by each new-flow target-item subcontract outbound line';
