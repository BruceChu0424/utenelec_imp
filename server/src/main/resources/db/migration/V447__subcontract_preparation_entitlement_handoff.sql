-- V447: exact cross-analysis entitlement handoff for subcontract preparation.
--
-- V436 creates an independent SUBCONTRACT_PREPARATION material analysis for a
-- MAKE_THEN_OUTBOUND order line.  V307/V313/V337 deliberately keep each exact
-- stock peg's immutable origin, so changing exact_peg.beneficiary_* or using
-- V309's manual reallocation/priority semantics would destroy provenance.  V447
-- therefore adds a dedicated append-only handoff ledger:
--   * parent-output TAKEOVER/RESTORE moves recursive requirement ownership;
--   * relative BOM UUID paths plus goods/color/unit UUIDs map exact rows;
--   * supply-allocation claims carry not-yet-arrived exact supply;
--   * SUBCONTRACT_HANDOFF_OUT/IN moves only the current entitlement beneficiary;
--   * RELEASE/RESTORE can reverse a still-unused handoff without changing stock.
-- stock_reservations and preplan_analysis_stock_exact_pegs remain immutable
-- physical/origin evidence.  Historical V298 pool reservations are never guessed.

-- A source-linked preparation already started by a pre-V447 application cannot
-- be reconstructed safely: neither a relative BOM snapshot nor the exact lots
-- transferred at START are provable after the fact.  Fail the forward migration
-- instead of silently leaving the original and preparation analyses both entitled.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM subcontract_material_plan_items plan_item
        JOIN subcontract_order_items order_item
          ON order_item.id = plan_item.order_item_id
         AND order_item.is_deleted = FALSE
        WHERE plan_item.is_deleted = FALSE
          AND plan_item.flow_mode = 'MAKE_THEN_OUTBOUND'
          AND plan_item.preparation_analysis_id IS NOT NULL
          AND plan_item.preparation_analysis_item_id IS NOT NULL
          AND plan_item.preparation_status NOT IN ('ACTION_REQUIRED', 'CANCELLED')
          AND order_item.application_item_id IS NOT NULL
          AND EXISTS (
              SELECT 1
              FROM preplan_supply_action_allocations allocation
              JOIN preplan_supply_actions action
                ON action.id = allocation.action_id
               AND action.analysis_id = allocation.analysis_id
               AND action.route = 'SUBCONTRACT'
               AND action.external_document_type = 'SUBCONTRACT_APPLICATION'
               AND action.status <> 'CANCELLED'
              WHERE allocation.external_item_id = order_item.application_item_id
          )
    ) THEN
        RAISE EXCEPTION
            'V447 cannot prove a pre-existing source-linked subcontract preparation handoff; restore the pre-V447 task state before migration'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_subcontract_handoff_upgrade_preflight';
    END IF;
END;
$$;

CREATE TABLE preplan_subcontract_requirement_handoffs (
    id                                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_item_id                        UUID NOT NULL
        REFERENCES subcontract_material_plan_items(id) ON DELETE RESTRICT,
    source_supply_action_id             UUID NOT NULL
        REFERENCES preplan_supply_actions(id) ON DELETE RESTRICT,
    source_supply_action_allocation_id  UUID NOT NULL
        REFERENCES preplan_supply_action_allocations(id) ON DELETE RESTRICT,
    source_analysis_id                  UUID NOT NULL
        REFERENCES production_material_analyses(id) ON DELETE RESTRICT,
    source_analysis_item_id             UUID NOT NULL,
    source_parent_material_id           UUID NOT NULL,
    target_analysis_id                  UUID NOT NULL
        REFERENCES production_material_analyses(id) ON DELETE RESTRICT,
    target_analysis_item_id             UUID NOT NULL,
    warehouse_id                        UUID NOT NULL
        REFERENCES warehouses(id) ON DELETE RESTRICT,
    target_goods_id                     UUID NOT NULL
        REFERENCES goods(id) ON DELETE RESTRICT,
    target_color_id                     UUID
        REFERENCES colors(id) ON DELETE RESTRICT,
    target_unit_id                      UUID NOT NULL
        REFERENCES units(id) ON DELETE RESTRICT,
    parent_output_qty                   NUMERIC(18,4) NOT NULL,
    source_analysis_version             BIGINT NOT NULL,
    source_analysis_fingerprint         TEXT NOT NULL,
    target_analysis_version             BIGINT NOT NULL,
    target_analysis_fingerprint         TEXT NOT NULL,
    idempotency_key                     TEXT NOT NULL,
    request_hash                        TEXT NOT NULL,
    created_by                          UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    created_at                          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT preplan_subcontract_handoff_source_item_fk
        FOREIGN KEY (source_analysis_id, source_analysis_item_id)
        REFERENCES production_material_analysis_items(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_subcontract_handoff_source_material_fk
        FOREIGN KEY (source_analysis_id, source_parent_material_id)
        REFERENCES production_material_analysis_materials(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_subcontract_handoff_target_item_fk
        FOREIGN KEY (target_analysis_id, target_analysis_item_id)
        REFERENCES production_material_analysis_items(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_subcontract_handoff_source_action_fk
        FOREIGN KEY (source_analysis_id, source_supply_action_id)
        REFERENCES preplan_supply_actions(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_subcontract_handoff_source_allocation_fk
        FOREIGN KEY (source_analysis_id, source_supply_action_allocation_id)
        REFERENCES preplan_supply_action_allocations(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_subcontract_handoff_analysis_distinct_chk CHECK (
        source_analysis_id <> target_analysis_id
    ),
    CONSTRAINT preplan_subcontract_handoff_qty_chk CHECK (
        parent_output_qty > 0
    ),
    CONSTRAINT preplan_subcontract_handoff_snapshot_chk CHECK (
        source_analysis_version >= 0
        AND target_analysis_version >= 0
        AND source_analysis_fingerprint ~ '^[0-9a-f]{64}$'
        AND target_analysis_fingerprint ~ '^[0-9a-f]{64}$'
        AND request_hash ~ '^[0-9a-f]{64}$'
    ),
    CONSTRAINT preplan_subcontract_handoff_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 200
    ),
    CONSTRAINT uq_preplan_subcontract_handoff_plan_item UNIQUE (plan_item_id),
    CONSTRAINT uq_preplan_subcontract_handoff_idempotency UNIQUE (idempotency_key)
);

CREATE INDEX idx_preplan_subcontract_handoff_source
    ON preplan_subcontract_requirement_handoffs(
        source_analysis_id, source_parent_material_id, created_at, id);
CREATE INDEX idx_preplan_subcontract_handoff_target
    ON preplan_subcontract_requirement_handoffs(
        target_analysis_id, target_analysis_item_id, created_at, id);

CREATE TABLE preplan_subcontract_requirement_handoff_items (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    handoff_id                      UUID NOT NULL
        REFERENCES preplan_subcontract_requirement_handoffs(id)
        ON DELETE RESTRICT,
    position                        INTEGER NOT NULL,
    source_analysis_id              UUID NOT NULL,
    source_analysis_material_id     UUID NOT NULL,
    target_analysis_id              UUID NOT NULL,
    target_analysis_material_id     UUID NOT NULL,
    relative_bom_path               UUID[] NOT NULL,
    bom_item_id                     UUID NOT NULL
        REFERENCES goods_bom_items(id) ON DELETE RESTRICT,
    goods_id                        UUID NOT NULL
        REFERENCES goods(id) ON DELETE RESTRICT,
    color_id                        UUID
        REFERENCES colors(id) ON DELETE RESTRICT,
    unit_id                         UUID NOT NULL
        REFERENCES units(id) ON DELETE RESTRICT,
    source_required_qty_snapshot    NUMERIC(18,4) NOT NULL,
    target_required_qty_snapshot    NUMERIC(18,4) NOT NULL,
    transfer_capacity_qty           NUMERIC(18,4) NOT NULL,
    idempotency_key                 TEXT NOT NULL,
    created_by                      UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT preplan_subcontract_handoff_item_source_fk
        FOREIGN KEY (source_analysis_id, source_analysis_material_id)
        REFERENCES production_material_analysis_materials(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_subcontract_handoff_item_target_fk
        FOREIGN KEY (target_analysis_id, target_analysis_material_id)
        REFERENCES production_material_analysis_materials(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_subcontract_handoff_item_position_chk CHECK (position > 0),
    CONSTRAINT preplan_subcontract_handoff_item_path_chk CHECK (
        cardinality(relative_bom_path) > 0
        AND relative_bom_path[cardinality(relative_bom_path)] = bom_item_id
    ),
    CONSTRAINT preplan_subcontract_handoff_item_qty_chk CHECK (
        source_required_qty_snapshot > 0
        AND target_required_qty_snapshot > 0
        AND transfer_capacity_qty > 0
        AND transfer_capacity_qty = target_required_qty_snapshot
        AND transfer_capacity_qty <= source_required_qty_snapshot
    ),
    CONSTRAINT preplan_subcontract_handoff_item_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 240
    ),
    CONSTRAINT uq_preplan_subcontract_handoff_item_position
        UNIQUE (handoff_id, position),
    CONSTRAINT uq_preplan_subcontract_handoff_item_target
        UNIQUE (handoff_id, target_analysis_material_id),
    CONSTRAINT uq_preplan_subcontract_handoff_item_pair
        UNIQUE (handoff_id, source_analysis_material_id,
                target_analysis_material_id),
    CONSTRAINT uq_preplan_subcontract_handoff_item_idempotency
        UNIQUE (idempotency_key)
);

CREATE INDEX idx_preplan_subcontract_handoff_item_source
    ON preplan_subcontract_requirement_handoff_items(
        source_analysis_id, source_analysis_material_id, handoff_id);
CREATE INDEX idx_preplan_subcontract_handoff_item_target_lookup
    ON preplan_subcontract_requirement_handoff_items(
        target_analysis_id, target_analysis_material_id, handoff_id);

CREATE TABLE preplan_subcontract_requirement_supply_claims (
    id                                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    handoff_item_id                     UUID NOT NULL
        REFERENCES preplan_subcontract_requirement_handoff_items(id)
        ON DELETE RESTRICT,
    source_analysis_id                  UUID NOT NULL,
    source_supply_action_id             UUID NOT NULL,
    source_supply_action_allocation_id  UUID NOT NULL,
    claimed_qty                         NUMERIC(18,4) NOT NULL,
    idempotency_key                     TEXT NOT NULL,
    created_by                          UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    created_at                          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT preplan_subcontract_supply_claim_action_fk
        FOREIGN KEY (source_analysis_id, source_supply_action_id)
        REFERENCES preplan_supply_actions(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_subcontract_supply_claim_allocation_fk
        FOREIGN KEY (source_analysis_id, source_supply_action_allocation_id)
        REFERENCES preplan_supply_action_allocations(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_subcontract_supply_claim_qty_chk CHECK (claimed_qty > 0),
    CONSTRAINT preplan_subcontract_supply_claim_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 240
    ),
    CONSTRAINT uq_preplan_subcontract_supply_claim_item_allocation
        UNIQUE (handoff_item_id, source_supply_action_allocation_id),
    CONSTRAINT uq_preplan_subcontract_supply_claim_idempotency
        UNIQUE (idempotency_key)
);

CREATE INDEX idx_preplan_subcontract_supply_claim_allocation
    ON preplan_subcontract_requirement_supply_claims(
        source_supply_action_allocation_id, created_at, id);

CREATE TABLE preplan_subcontract_entitlement_handoff_slices (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    handoff_item_id                 UUID NOT NULL
        REFERENCES preplan_subcontract_requirement_handoff_items(id)
        ON DELETE RESTRICT,
    supply_claim_id                 UUID
        REFERENCES preplan_subcontract_requirement_supply_claims(id)
        ON DELETE RESTRICT,
    stock_reservation_id            UUID NOT NULL
        REFERENCES stock_reservations(id) ON DELETE RESTRICT,
    source_entitlement_event_id     UUID NOT NULL
        REFERENCES preplan_stock_entitlement_events(id) ON DELETE RESTRICT,
    source_exact_peg_id             UUID NOT NULL
        REFERENCES preplan_analysis_stock_exact_pegs(id) ON DELETE RESTRICT,
    qty                             NUMERIC(18,4) NOT NULL,
    idempotency_key                 TEXT NOT NULL,
    created_by                      UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT preplan_subcontract_handoff_slice_qty_chk CHECK (qty > 0),
    CONSTRAINT preplan_subcontract_handoff_slice_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 260
    ),
    CONSTRAINT uq_preplan_subcontract_handoff_slice_source
        UNIQUE (handoff_item_id, source_entitlement_event_id),
    CONSTRAINT uq_preplan_subcontract_handoff_slice_idempotency
        UNIQUE (idempotency_key)
);

CREATE INDEX idx_preplan_subcontract_handoff_slice_claim
    ON preplan_subcontract_entitlement_handoff_slices(
        supply_claim_id, created_at, id)
    WHERE supply_claim_id IS NOT NULL;
CREATE INDEX idx_preplan_subcontract_handoff_slice_reservation
    ON preplan_subcontract_entitlement_handoff_slices(
        stock_reservation_id, created_at, id);

CREATE TABLE preplan_subcontract_requirement_handoff_events (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    handoff_id              UUID NOT NULL
        REFERENCES preplan_subcontract_requirement_handoffs(id)
        ON DELETE RESTRICT,
    event_type              TEXT NOT NULL,
    qty                     NUMERIC(18,4) NOT NULL,
    counter_event_id        UUID
        REFERENCES preplan_subcontract_requirement_handoff_events(id)
        ON DELETE RESTRICT,
    reason                  TEXT NOT NULL,
    idempotency_key         TEXT NOT NULL,
    created_by              UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT preplan_subcontract_requirement_event_type_chk CHECK (
        event_type IN ('TAKEOVER', 'RESTORE')
    ),
    CONSTRAINT preplan_subcontract_requirement_event_qty_chk CHECK (qty > 0),
    CONSTRAINT preplan_subcontract_requirement_event_shape_chk CHECK (
        (event_type = 'TAKEOVER' AND counter_event_id IS NULL)
        OR (event_type = 'RESTORE' AND counter_event_id IS NOT NULL)
    ),
    CONSTRAINT preplan_subcontract_requirement_event_reason_chk CHECK (
        reason = btrim(reason) AND length(reason) BETWEEN 2 AND 1000
    ),
    CONSTRAINT preplan_subcontract_requirement_event_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 260
    ),
    CONSTRAINT uq_preplan_subcontract_requirement_event_idempotency
        UNIQUE (idempotency_key)
);

CREATE UNIQUE INDEX uq_preplan_subcontract_requirement_takeover
    ON preplan_subcontract_requirement_handoff_events(handoff_id)
    WHERE event_type = 'TAKEOVER';
CREATE UNIQUE INDEX uq_preplan_subcontract_requirement_restore
    ON preplan_subcontract_requirement_handoff_events(counter_event_id)
    WHERE event_type = 'RESTORE';
CREATE INDEX idx_preplan_subcontract_requirement_event_handoff
    ON preplan_subcontract_requirement_handoff_events(
        handoff_id, created_at, id);

-- Every V447 fact is append-only.  State is reconstructed from paired events;
-- no status/counter column may be updated in place.
CREATE OR REPLACE FUNCTION fn_guard_preplan_subcontract_handoff_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'preplan subcontract handoff facts are append-only'
        USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER trg_guard_preplan_subcontract_requirement_handoffs
    BEFORE UPDATE OR DELETE ON preplan_subcontract_requirement_handoffs
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_subcontract_handoff_mutation();
CREATE TRIGGER trg_guard_preplan_subcontract_requirement_handoff_items
    BEFORE UPDATE OR DELETE ON preplan_subcontract_requirement_handoff_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_subcontract_handoff_mutation();
CREATE TRIGGER trg_guard_preplan_subcontract_requirement_supply_claims
    BEFORE UPDATE OR DELETE ON preplan_subcontract_requirement_supply_claims
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_subcontract_handoff_mutation();
CREATE TRIGGER trg_guard_preplan_subcontract_entitlement_handoff_slices
    BEFORE UPDATE OR DELETE ON preplan_subcontract_entitlement_handoff_slices
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_subcontract_handoff_mutation();
CREATE TRIGGER trg_guard_preplan_subcontract_requirement_handoff_events
    BEFORE UPDATE OR DELETE ON preplan_subcontract_requirement_handoff_events
    FOR EACH ROW EXECUTE FUNCTION fn_guard_preplan_subcontract_handoff_mutation();

CREATE TRIGGER trg_audit_preplan_subcontract_requirement_handoffs
    AFTER INSERT OR UPDATE OR DELETE ON preplan_subcontract_requirement_handoffs
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_preplan_subcontract_requirement_handoff_items
    AFTER INSERT OR UPDATE OR DELETE
    ON preplan_subcontract_requirement_handoff_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_preplan_subcontract_requirement_supply_claims
    AFTER INSERT OR UPDATE OR DELETE
    ON preplan_subcontract_requirement_supply_claims
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_preplan_subcontract_entitlement_handoff_slices
    AFTER INSERT OR UPDATE OR DELETE
    ON preplan_subcontract_entitlement_handoff_slices
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_preplan_subcontract_requirement_handoff_events
    AFTER INSERT OR UPDATE OR DELETE
    ON preplan_subcontract_requirement_handoff_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- Freeze the versions/fingerprints used to build the canonical request hash at
-- the instant the header is inserted.  The same transaction may refresh both
-- analyses after inserting the append-only ledger, so final-state validation
-- deliberately does not require the live version to remain equal.
CREATE OR REPLACE FUNCTION fn_check_preplan_subcontract_handoff_snapshot()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    source_analysis production_material_analyses%ROWTYPE;
    target_analysis production_material_analyses%ROWTYPE;
BEGIN
    SELECT * INTO source_analysis
    FROM production_material_analyses
    WHERE id = NEW.source_analysis_id
    FOR UPDATE;
    SELECT * INTO target_analysis
    FROM production_material_analyses
    WHERE id = NEW.target_analysis_id
    FOR UPDATE;

    IF source_analysis.id IS NULL
       OR target_analysis.id IS NULL
       OR source_analysis.is_deleted IS DISTINCT FROM FALSE
       OR target_analysis.is_deleted IS DISTINCT FROM FALSE
       OR source_analysis.status NOT IN ('ACTIVE', 'PARTIALLY_PLANNED')
       OR target_analysis.status NOT IN ('ACTIVE', 'PARTIALLY_PLANNED')
       OR source_analysis.warehouse_id IS DISTINCT FROM NEW.warehouse_id
       OR target_analysis.warehouse_id IS DISTINCT FROM NEW.warehouse_id
       OR source_analysis.version IS DISTINCT FROM NEW.source_analysis_version
       OR source_analysis.fingerprint
            IS DISTINCT FROM NEW.source_analysis_fingerprint
       OR target_analysis.version IS DISTINCT FROM NEW.target_analysis_version
       OR target_analysis.fingerprint
            IS DISTINCT FROM NEW.target_analysis_fingerprint THEN
        RAISE EXCEPTION
            'subcontract handoff analysis snapshot changed before capture'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_subcontract_handoff_snapshot_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_preplan_subcontract_handoff_snapshot
    BEFORE INSERT ON preplan_subcontract_requirement_handoffs
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_preplan_subcontract_handoff_snapshot();

-- Final lineage proof.  It is deferred because START creates the target
-- analysis first, records this handoff, and only then writes the V436
-- preparation_analysis_* link in the same transaction.
CREATE OR REPLACE FUNCTION fn_assert_preplan_subcontract_requirement_handoff(
    p_handoff_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    handoff preplan_subcontract_requirement_handoffs%ROWTYPE;
    lineage_count BIGINT;
    target_positive_count BIGINT;
    mapped_count BIGINT;
BEGIN
    SELECT * INTO handoff
    FROM preplan_subcontract_requirement_handoffs
    WHERE id = p_handoff_id;
    IF handoff.id IS NULL THEN RETURN; END IF;

    SELECT COUNT(*) INTO lineage_count
    FROM subcontract_material_plan_items plan_item
    JOIN subcontract_order_items order_item
      ON order_item.id = plan_item.order_item_id
     AND order_item.is_deleted = FALSE
    JOIN subcontract_application_items application_item
      ON application_item.id = order_item.application_item_id
     AND application_item.is_deleted = FALSE
    JOIN preplan_supply_action_allocations allocation
      ON allocation.id = handoff.source_supply_action_allocation_id
     AND allocation.analysis_id = handoff.source_analysis_id
     AND allocation.action_id = handoff.source_supply_action_id
     AND allocation.external_item_id = application_item.id
    JOIN preplan_supply_actions action
      ON action.id = allocation.action_id
     AND action.analysis_id = allocation.analysis_id
     AND action.route = 'SUBCONTRACT'
     AND action.status <> 'CANCELLED'
     AND action.external_document_type = 'SUBCONTRACT_APPLICATION'
     AND action.external_document_id = application_item.application_id
    JOIN production_material_analysis_materials source_parent
      ON source_parent.id = handoff.source_parent_material_id
     AND source_parent.analysis_id = handoff.source_analysis_id
     AND source_parent.analysis_item_id = handoff.source_analysis_item_id
     AND source_parent.active = TRUE
     AND source_parent.goods_id = plan_item.goods_id
     AND source_parent.color_id IS NOT DISTINCT FROM plan_item.color_id
     AND source_parent.unit_id = plan_item.unit_id
     AND COALESCE(source_parent.confirmed_route,
                  source_parent.source_suggestion) = 'SUBCONTRACT'
    JOIN production_material_analysis_items target_item
      ON target_item.id = handoff.target_analysis_item_id
     AND target_item.analysis_id = handoff.target_analysis_id
     AND target_item.source_type = 'SUBCONTRACT_PREPARATION'
     AND target_item.is_deleted = FALSE
     AND target_item.source_ref = 'SC-PREP:' || order_item.id::text
     AND target_item.goods_id = plan_item.goods_id
     AND target_item.color_id IS NOT DISTINCT FROM plan_item.color_id
     AND target_item.unit_id = plan_item.unit_id
     AND target_item.requested_qty = plan_item.planned_qty
    WHERE plan_item.id = handoff.plan_item_id
      AND plan_item.is_deleted = FALSE
      AND plan_item.flow_mode = 'MAKE_THEN_OUTBOUND'
      AND plan_item.preparation_status IN (
          'IN_PREPARATION', 'WAITING_FQC', 'WAITING_INBOUND',
          'READY_OUTBOUND', 'OUTBOUND_COMPLETE')
      AND plan_item.preparation_analysis_id = handoff.target_analysis_id
      AND plan_item.preparation_analysis_item_id = handoff.target_analysis_item_id
      AND plan_item.preparation_warehouse_id = handoff.warehouse_id
      AND plan_item.goods_id = handoff.target_goods_id
      AND plan_item.color_id IS NOT DISTINCT FROM handoff.target_color_id
      AND plan_item.unit_id = handoff.target_unit_id
      AND plan_item.planned_qty = handoff.parent_output_qty;

    IF lineage_count <> 1 THEN
        RAISE EXCEPTION
            'subcontract requirement handoff lacks one exact source/target lineage'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_subcontract_handoff_lineage_guard';
    END IF;

    SELECT COUNT(*) INTO target_positive_count
    FROM production_material_analysis_materials material
    WHERE material.analysis_id = handoff.target_analysis_id
      AND material.analysis_item_id = handoff.target_analysis_item_id
      AND material.active = TRUE
      AND material.required_qty > 0;
    SELECT COUNT(*) INTO mapped_count
    FROM preplan_subcontract_requirement_handoff_items item
    WHERE item.handoff_id = handoff.id;
    IF target_positive_count = 0 OR mapped_count <> target_positive_count THEN
        RAISE EXCEPTION
            'subcontract handoff must map every positive target BOM material exactly once'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_subcontract_handoff_mapping_complete_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_check_preplan_subcontract_requirement_handoff()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        PERFORM fn_assert_preplan_subcontract_requirement_handoff(OLD.id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        PERFORM fn_assert_preplan_subcontract_requirement_handoff(NEW.id);
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_check_preplan_subcontract_requirement_handoff
    AFTER INSERT OR UPDATE OR DELETE
    ON preplan_subcontract_requirement_handoffs
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_preplan_subcontract_requirement_handoff();

-- Old application binaries must not be able to advance a source-linked V436
-- task without writing the V447 ledger.  Direct/manual subcontract orders have
-- no application_item_id and therefore remain outside this cross-analysis rule.
CREATE OR REPLACE FUNCTION fn_assert_subcontract_preparation_has_handoff(
    p_plan_item_id UUID
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM subcontract_material_plan_items plan_item
        JOIN subcontract_order_items order_item
          ON order_item.id = plan_item.order_item_id
         AND order_item.is_deleted = FALSE
        WHERE plan_item.id = p_plan_item_id
          AND plan_item.is_deleted = FALSE
          AND plan_item.flow_mode = 'MAKE_THEN_OUTBOUND'
          AND plan_item.preparation_analysis_id IS NOT NULL
          AND plan_item.preparation_status NOT IN ('ACTION_REQUIRED', 'CANCELLED')
          AND order_item.application_item_id IS NOT NULL
          AND EXISTS (
              SELECT 1
              FROM preplan_supply_action_allocations allocation
              JOIN preplan_supply_actions action
                ON action.id = allocation.action_id
               AND action.analysis_id = allocation.analysis_id
               AND action.route = 'SUBCONTRACT'
               AND action.external_document_type = 'SUBCONTRACT_APPLICATION'
               AND action.status <> 'CANCELLED'
              WHERE allocation.external_item_id = order_item.application_item_id
          )
          AND NOT EXISTS (
              SELECT 1
              FROM preplan_subcontract_requirement_handoffs handoff
              WHERE handoff.plan_item_id = plan_item.id
                AND handoff.target_analysis_id =
                    plan_item.preparation_analysis_id
                AND handoff.target_analysis_item_id =
                    plan_item.preparation_analysis_item_id
          )
    ) THEN
        RAISE EXCEPTION
            'source-linked subcontract preparation requires an exact V447 handoff'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'subcontract_preparation_handoff_required_guard';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_check_subcontract_preparation_has_handoff()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        PERFORM fn_assert_subcontract_preparation_has_handoff(OLD.id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        PERFORM fn_assert_subcontract_preparation_has_handoff(NEW.id);
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_subcontract_preparation_handoff_required
    AFTER INSERT OR UPDATE OR DELETE ON subcontract_material_plan_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_subcontract_preparation_has_handoff();

CREATE OR REPLACE FUNCTION fn_check_preplan_subcontract_handoff_item()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    handoff preplan_subcontract_requirement_handoffs%ROWTYPE;
    source_parent production_material_analysis_materials%ROWTYPE;
    source_material production_material_analysis_materials%ROWTYPE;
    target_material production_material_analysis_materials%ROWTYPE;
    source_relative UUID[];
    target_relative UUID[];
BEGIN
    SELECT * INTO handoff
    FROM preplan_subcontract_requirement_handoffs
    WHERE id = NEW.handoff_id
    FOR UPDATE;
    SELECT * INTO source_parent
    FROM production_material_analysis_materials
    WHERE id = handoff.source_parent_material_id
    FOR UPDATE;
    SELECT * INTO source_material
    FROM production_material_analysis_materials
    WHERE id = NEW.source_analysis_material_id
    FOR UPDATE;
    SELECT * INTO target_material
    FROM production_material_analysis_materials
    WHERE id = NEW.target_analysis_material_id
    FOR UPDATE;

    IF source_material.node_key LIKE source_parent.node_key || '/%' THEN
        source_relative := string_to_array(
            substring(source_material.node_key
                      FROM length(source_parent.node_key) + 2), '/')::UUID[];
    END IF;
    target_relative := string_to_array(target_material.node_key, '/')::UUID[];

    IF handoff.id IS NULL
       OR source_parent.id IS NULL
       OR source_material.id IS NULL
       OR target_material.id IS NULL
       OR NEW.source_analysis_id IS DISTINCT FROM handoff.source_analysis_id
       OR NEW.target_analysis_id IS DISTINCT FROM handoff.target_analysis_id
       OR source_material.analysis_id IS DISTINCT FROM handoff.source_analysis_id
       OR source_material.analysis_item_id
            IS DISTINCT FROM handoff.source_analysis_item_id
       OR source_material.active IS DISTINCT FROM TRUE
       OR target_material.analysis_id IS DISTINCT FROM handoff.target_analysis_id
       OR target_material.analysis_item_id
            IS DISTINCT FROM handoff.target_analysis_item_id
       OR target_material.active IS DISTINCT FROM TRUE
       OR source_relative IS DISTINCT FROM NEW.relative_bom_path
       OR target_relative IS DISTINCT FROM NEW.relative_bom_path
       OR source_material.bom_item_id IS DISTINCT FROM NEW.bom_item_id
       OR target_material.bom_item_id IS DISTINCT FROM NEW.bom_item_id
       OR source_material.goods_id IS DISTINCT FROM NEW.goods_id
       OR target_material.goods_id IS DISTINCT FROM NEW.goods_id
       OR source_material.color_id IS DISTINCT FROM NEW.color_id
       OR target_material.color_id IS DISTINCT FROM NEW.color_id
       OR source_material.unit_id IS DISTINCT FROM NEW.unit_id
       OR target_material.unit_id IS DISTINCT FROM NEW.unit_id
       OR source_material.required_qty
            IS DISTINCT FROM NEW.source_required_qty_snapshot
       OR target_material.required_qty
            IS DISTINCT FROM NEW.target_required_qty_snapshot THEN
        RAISE EXCEPTION
            'subcontract handoff item must match one exact relative BOM UUID path and material dimension'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_subcontract_handoff_item_identity_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_preplan_subcontract_handoff_item
    BEFORE INSERT ON preplan_subcontract_requirement_handoff_items
    FOR EACH ROW EXECUTE FUNCTION fn_check_preplan_subcontract_handoff_item();

CREATE OR REPLACE FUNCTION fn_check_preplan_subcontract_requirement_event()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    handoff preplan_subcontract_requirement_handoffs%ROWTYPE;
    counter preplan_subcontract_requirement_handoff_events%ROWTYPE;
BEGIN
    SELECT * INTO handoff
    FROM preplan_subcontract_requirement_handoffs
    WHERE id = NEW.handoff_id
    FOR UPDATE;
    IF NEW.counter_event_id IS NOT NULL THEN
        SELECT * INTO counter
        FROM preplan_subcontract_requirement_handoff_events
        WHERE id = NEW.counter_event_id
        FOR UPDATE;
    END IF;

    IF handoff.id IS NULL
       OR NEW.qty IS DISTINCT FROM handoff.parent_output_qty
       OR (NEW.event_type = 'TAKEOVER' AND NEW.counter_event_id IS NOT NULL)
       OR (NEW.event_type = 'RESTORE' AND (
           counter.id IS NULL
           OR counter.handoff_id IS DISTINCT FROM handoff.id
           OR counter.event_type IS DISTINCT FROM 'TAKEOVER'
           OR counter.qty IS DISTINCT FROM NEW.qty
       )) THEN
        RAISE EXCEPTION 'invalid subcontract requirement handoff event'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_subcontract_requirement_event_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_preplan_subcontract_requirement_event
    BEFORE INSERT ON preplan_subcontract_requirement_handoff_events
    FOR EACH ROW EXECUTE FUNCTION
        fn_check_preplan_subcontract_requirement_event();

CREATE OR REPLACE FUNCTION fn_validate_preplan_subcontract_requirement_totals()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_handoff_id UUID;
    handoff preplan_subcontract_requirement_handoffs%ROWTYPE;
    takeover_qty NUMERIC(18,4);
    restore_qty NUMERIC(18,4);
BEGIN
    IF TG_TABLE_NAME = 'preplan_subcontract_requirement_handoffs' THEN
        v_handoff_id := COALESCE(NEW.id, OLD.id);
    ELSE
        v_handoff_id := COALESCE(NEW.handoff_id, OLD.handoff_id);
    END IF;
    SELECT * INTO handoff
    FROM preplan_subcontract_requirement_handoffs
    WHERE id = v_handoff_id;
    IF handoff.id IS NULL THEN RETURN NEW; END IF;

    SELECT COALESCE(SUM(event.qty), 0) INTO takeover_qty
    FROM preplan_subcontract_requirement_handoff_events event
    WHERE event.handoff_id = handoff.id AND event.event_type = 'TAKEOVER';
    SELECT COALESCE(SUM(event.qty), 0) INTO restore_qty
    FROM preplan_subcontract_requirement_handoff_events event
    WHERE event.handoff_id = handoff.id AND event.event_type = 'RESTORE';
    IF takeover_qty IS DISTINCT FROM handoff.parent_output_qty
       OR restore_qty NOT IN (0, handoff.parent_output_qty) THEN
        RAISE EXCEPTION
            'subcontract requirement TAKEOVER must equal parent output and RESTORE must be all-or-nothing'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_subcontract_requirement_total_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_preplan_subcontract_requirement_header
    AFTER INSERT ON preplan_subcontract_requirement_handoffs
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_preplan_subcontract_requirement_totals();
CREATE CONSTRAINT TRIGGER trg_validate_preplan_subcontract_requirement_events
    AFTER INSERT ON preplan_subcontract_requirement_handoff_events
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_preplan_subcontract_requirement_totals();

CREATE VIEW v_preplan_subcontract_requirement_handoff_state AS
SELECT handoff.*,
       takeover.qty AS takeover_qty,
       COALESCE(restored.restored_qty, 0)::numeric AS restored_qty,
       (takeover.qty - COALESCE(restored.restored_qty, 0))::numeric
           AS active_parent_output_qty,
       CASE WHEN COALESCE(restored.restored_qty, 0) = takeover.qty
            THEN 'RESTORED' ELSE 'ACTIVE' END AS state
FROM preplan_subcontract_requirement_handoffs handoff
JOIN preplan_subcontract_requirement_handoff_events takeover
  ON takeover.handoff_id = handoff.id
 AND takeover.event_type = 'TAKEOVER'
LEFT JOIN LATERAL (
    SELECT SUM(event.qty)::numeric AS restored_qty
    FROM preplan_subcontract_requirement_handoff_events event
    WHERE event.handoff_id = handoff.id
      AND event.event_type = 'RESTORE'
      AND event.counter_event_id = takeover.id
) restored ON TRUE;

CREATE VIEW v_preplan_subcontract_parent_output_claim_balance AS
SELECT state.source_analysis_id,
       state.source_analysis_item_id,
       state.source_parent_material_id,
       SUM(state.active_parent_output_qty)::numeric AS active_parent_output_qty
FROM v_preplan_subcontract_requirement_handoff_state state
GROUP BY state.source_analysis_id,
         state.source_analysis_item_id,
         state.source_parent_material_id
HAVING SUM(state.active_parent_output_qty) > 0;

CREATE OR REPLACE FUNCTION fn_check_preplan_subcontract_supply_claim()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    item preplan_subcontract_requirement_handoff_items%ROWTYPE;
    handoff preplan_subcontract_requirement_handoffs%ROWTYPE;
    action preplan_supply_actions%ROWTYPE;
    allocation preplan_supply_action_allocations%ROWTYPE;
BEGIN
    SELECT * INTO item
    FROM preplan_subcontract_requirement_handoff_items
    WHERE id = NEW.handoff_item_id
    FOR UPDATE;
    SELECT * INTO handoff
    FROM preplan_subcontract_requirement_handoffs
    WHERE id = item.handoff_id
    FOR UPDATE;
    SELECT * INTO action
    FROM preplan_supply_actions
    WHERE id = NEW.source_supply_action_id
    FOR UPDATE;
    SELECT * INTO allocation
    FROM preplan_supply_action_allocations
    WHERE id = NEW.source_supply_action_allocation_id
    FOR UPDATE;

    IF item.id IS NULL
       OR handoff.id IS NULL
       OR action.id IS NULL
       OR allocation.id IS NULL
       OR NEW.source_analysis_id IS DISTINCT FROM item.source_analysis_id
       OR action.analysis_id IS DISTINCT FROM item.source_analysis_id
       OR action.status = 'CANCELLED'
       OR action.route NOT IN ('BUY', 'MAKE', 'SUBCONTRACT')
       OR allocation.analysis_id IS DISTINCT FROM item.source_analysis_id
       OR allocation.action_id IS DISTINCT FROM action.id
       OR allocation.analysis_material_id
            IS DISTINCT FROM item.source_analysis_material_id
       OR NEW.claimed_qty > item.transfer_capacity_qty
       OR NEW.claimed_qty > allocation.allocated_qty
       OR EXISTS (
           SELECT 1
           FROM preplan_subcontract_requirement_handoff_events restored
           WHERE restored.handoff_id = handoff.id
             AND restored.event_type = 'RESTORE'
       ) THEN
        RAISE EXCEPTION 'invalid subcontract preparation future supply claim'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_subcontract_supply_claim_identity_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_preplan_subcontract_supply_claim
    BEFORE INSERT ON preplan_subcontract_requirement_supply_claims
    FOR EACH ROW EXECUTE FUNCTION fn_check_preplan_subcontract_supply_claim();

-- Restored handoffs no longer reserve a future allocation.  This permits a new
-- order/plan item to take over the same remaining source allocation without
-- mutating or deleting the historical claim.
CREATE OR REPLACE FUNCTION fn_validate_preplan_subcontract_supply_claim_totals()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    allocation_id UUID;
    allocation preplan_supply_action_allocations%ROWTYPE;
    active_claimed NUMERIC(18,4);
BEGIN
    IF TG_TABLE_NAME = 'preplan_supply_action_allocations' THEN
        allocation_id := COALESCE(NEW.id, OLD.id);
    ELSE
        allocation_id := COALESCE(
            NEW.source_supply_action_allocation_id,
            OLD.source_supply_action_allocation_id);
    END IF;
    SELECT * INTO allocation
    FROM preplan_supply_action_allocations
    WHERE id = allocation_id;
    IF allocation.id IS NULL THEN RETURN NEW; END IF;

    SELECT COALESCE(SUM(claim.claimed_qty), 0)
    INTO active_claimed
    FROM preplan_subcontract_requirement_supply_claims claim
    JOIN preplan_subcontract_requirement_handoff_items item
      ON item.id = claim.handoff_item_id
    JOIN v_preplan_subcontract_requirement_handoff_state state
      ON state.id = item.handoff_id
     AND state.state = 'ACTIVE'
    WHERE claim.source_supply_action_allocation_id = allocation.id;
    IF active_claimed > allocation.allocated_qty THEN
        RAISE EXCEPTION
            'active subcontract preparation claims exceed source allocation capacity'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_subcontract_supply_claim_capacity_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_preplan_subcontract_supply_claim_rows
    AFTER INSERT ON preplan_subcontract_requirement_supply_claims
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_preplan_subcontract_supply_claim_totals();
CREATE CONSTRAINT TRIGGER trg_validate_preplan_subcontract_supply_claim_allocation
    AFTER INSERT OR UPDATE OR DELETE ON preplan_supply_action_allocations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_preplan_subcontract_supply_claim_totals();

CREATE VIEW v_preplan_subcontract_requirement_supply_claim_state AS
SELECT claim.*,
       state.state AS handoff_state,
       COALESCE(arrived.arrived_qty, 0)::numeric AS arrived_qty,
       CASE WHEN state.state = 'ACTIVE'
            THEN GREATEST(claim.claimed_qty
                          - COALESCE(arrived.arrived_qty, 0), 0)
            ELSE 0::numeric END AS future_qty
FROM preplan_subcontract_requirement_supply_claims claim
JOIN preplan_subcontract_requirement_handoff_items item
  ON item.id = claim.handoff_item_id
JOIN v_preplan_subcontract_requirement_handoff_state state
  ON state.id = item.handoff_id
LEFT JOIN LATERAL (
    SELECT SUM(slice.qty)::numeric AS arrived_qty
    FROM preplan_subcontract_entitlement_handoff_slices slice
    WHERE slice.supply_claim_id = claim.id
) arrived ON TRUE;

CREATE VIEW v_preplan_subcontract_target_future_supply AS
SELECT item.target_analysis_id,
       item.target_analysis_material_id,
       SUM(claim.future_qty)::numeric AS future_qty
FROM v_preplan_subcontract_requirement_supply_claim_state claim
JOIN preplan_subcontract_requirement_handoff_items item
  ON item.id = claim.handoff_item_id
WHERE claim.future_qty > 0
GROUP BY item.target_analysis_id, item.target_analysis_material_id;

CREATE OR REPLACE FUNCTION fn_check_preplan_subcontract_handoff_slice()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    item preplan_subcontract_requirement_handoff_items%ROWTYPE;
    handoff preplan_subcontract_requirement_handoffs%ROWTYPE;
    claim preplan_subcontract_requirement_supply_claims%ROWTYPE;
    reservation stock_reservations%ROWTYPE;
    source_event preplan_stock_entitlement_events%ROWTYPE;
    exact preplan_analysis_stock_exact_pegs%ROWTYPE;
    source_remaining NUMERIC(18,4);
    target_transferred NUMERIC(18,4);
BEGIN
    SELECT * INTO item
    FROM preplan_subcontract_requirement_handoff_items
    WHERE id = NEW.handoff_item_id
    FOR UPDATE;
    SELECT * INTO handoff
    FROM preplan_subcontract_requirement_handoffs
    WHERE id = item.handoff_id
    FOR UPDATE;
    IF NEW.supply_claim_id IS NOT NULL THEN
        SELECT * INTO claim
        FROM preplan_subcontract_requirement_supply_claims
        WHERE id = NEW.supply_claim_id
        FOR UPDATE;
    END IF;
    SELECT * INTO reservation
    FROM stock_reservations
    WHERE id = NEW.stock_reservation_id
    FOR UPDATE;
    SELECT * INTO source_event
    FROM preplan_stock_entitlement_events
    WHERE id = NEW.source_entitlement_event_id
    FOR UPDATE;
    SELECT * INTO exact
    FROM preplan_analysis_stock_exact_pegs
    WHERE id = NEW.source_exact_peg_id;

    SELECT source_event.qty - COALESCE(SUM(used.qty), 0)
    INTO source_remaining
    FROM preplan_stock_entitlement_events used
    WHERE used.source_entitlement_event_id = source_event.id
      AND used.event_type IN (
          'MAKE_DELEGATE_OUT', 'SUBCONTRACT_HANDOFF_OUT',
          'REALLOCATE_OUT', 'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
    GROUP BY source_event.qty;
    source_remaining := COALESCE(source_remaining, source_event.qty);
    SELECT COALESCE(SUM(slice.qty), 0)
    INTO target_transferred
    FROM preplan_subcontract_entitlement_handoff_slices slice
    WHERE slice.handoff_item_id = item.id
      AND slice.id <> NEW.id;

    IF item.id IS NULL
       OR handoff.id IS NULL
       OR reservation.id IS NULL
       OR source_event.id IS NULL
       OR exact.id IS NULL
       OR reservation.owner_type IS DISTINCT FROM 'PREPLAN_ANALYSIS'
       OR reservation.purpose IS DISTINCT FROM 'PREPLAN_MATERIAL'
       OR reservation.owner_id IS DISTINCT FROM item.source_analysis_id
       OR reservation.status <> 0
       OR reservation.is_deleted IS DISTINCT FROM FALSE
       OR reservation.goods_id IS DISTINCT FROM item.goods_id
       OR reservation.color_id IS DISTINCT FROM item.color_id
       OR source_event.stock_reservation_id IS DISTINCT FROM reservation.id
       OR source_event.beneficiary_analysis_id
            IS DISTINCT FROM item.source_analysis_id
       OR source_event.beneficiary_analysis_material_id
            IS DISTINCT FROM item.source_analysis_material_id
       OR source_event.event_type NOT IN (
            'ORIGIN_IQC', 'ORIGIN_MAKE', 'MAKE_DELEGATE_IN',
            'SUBCONTRACT_HANDOFF_IN', 'RESTORE')
       OR source_event.reallocation_id IS NOT NULL
       OR source_event.source_exact_peg_id IS DISTINCT FROM exact.id
       OR exact.stock_reservation_id IS DISTINCT FROM reservation.id
       OR exact.origin_analysis_id IS DISTINCT FROM item.source_analysis_id
       OR exact.origin_analysis_material_id
            IS DISTINCT FROM item.source_analysis_material_id
       OR NEW.qty > source_remaining
       OR target_transferred + NEW.qty > item.transfer_capacity_qty
       OR (NEW.supply_claim_id IS NOT NULL AND (
            claim.id IS NULL
            OR claim.handoff_item_id IS DISTINCT FROM item.id
            OR exact.supply_action_allocation_id
                IS DISTINCT FROM claim.source_supply_action_allocation_id
       ))
       OR EXISTS (
           SELECT 1
           FROM preplan_subcontract_requirement_handoff_events restored
           WHERE restored.handoff_id = handoff.id
             AND restored.event_type = 'RESTORE'
       ) THEN
        RAISE EXCEPTION 'invalid subcontract exact entitlement handoff slice'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_subcontract_handoff_slice_identity_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_preplan_subcontract_handoff_slice
    BEFORE INSERT ON preplan_subcontract_entitlement_handoff_slices
    FOR EACH ROW EXECUTE FUNCTION fn_check_preplan_subcontract_handoff_slice();

ALTER TABLE preplan_stock_entitlement_events
    DROP CONSTRAINT preplan_entitlement_event_type_chk,
    ADD CONSTRAINT preplan_entitlement_event_type_chk CHECK (event_type IN (
        'ORIGIN_IQC', 'ORIGIN_MAKE',
        'MAKE_DELEGATE_IN', 'MAKE_DELEGATE_OUT',
        'SUBCONTRACT_HANDOFF_IN', 'SUBCONTRACT_HANDOFF_OUT',
        'REALLOCATE_IN', 'REALLOCATE_OUT',
        'PRIORITY_IN', 'PRIORITY_OUT',
        'PRIORITY_SATISFIED_IN_PLACE',
        'FORMALIZE', 'RESTORE', 'RELEASE'));

CREATE UNIQUE INDEX uq_preplan_subcontract_handoff_out_group
    ON preplan_stock_entitlement_events(event_group_id)
    WHERE event_type = 'SUBCONTRACT_HANDOFF_OUT';
CREATE UNIQUE INDEX uq_preplan_subcontract_handoff_in_group
    ON preplan_stock_entitlement_events(event_group_id)
    WHERE event_type = 'SUBCONTRACT_HANDOFF_IN';
CREATE UNIQUE INDEX uq_preplan_subcontract_handoff_in_counter
    ON preplan_stock_entitlement_events(counter_event_id)
    WHERE event_type = 'SUBCONTRACT_HANDOFF_IN';
CREATE INDEX idx_preplan_entitlement_subcontract_handoff
    ON preplan_stock_entitlement_events(
        event_group_id, event_type, created_at, id)
    WHERE event_type IN (
        'SUBCONTRACT_HANDOFF_OUT', 'SUBCONTRACT_HANDOFF_IN');

CREATE OR REPLACE VIEW v_preplan_stock_entitlement_lot_balance AS
SELECT positive.id AS entitlement_event_id,
       positive.event_group_id,
       positive.stock_reservation_id,
       positive.beneficiary_analysis_id,
       positive.beneficiary_analysis_material_id,
       positive.event_type AS origin_event_type,
       positive.reallocation_id,
       positive.source_exact_peg_id,
       positive.qty AS granted_qty,
       COALESCE(consumed.consumed_qty, 0)::numeric AS consumed_qty,
       (positive.qty - COALESCE(consumed.consumed_qty, 0))::numeric
           AS remaining_qty,
       positive.created_at,
       positive.id
FROM preplan_stock_entitlement_events positive
LEFT JOIN LATERAL (
    SELECT SUM(negative.qty)::numeric AS consumed_qty
    FROM preplan_stock_entitlement_events negative
    WHERE negative.source_entitlement_event_id = positive.id
      AND negative.event_type IN (
          'MAKE_DELEGATE_OUT', 'SUBCONTRACT_HANDOFF_OUT',
          'REALLOCATE_OUT', 'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
) consumed ON TRUE
WHERE positive.event_type IN (
    'ORIGIN_IQC', 'ORIGIN_MAKE', 'MAKE_DELEGATE_IN',
    'SUBCONTRACT_HANDOFF_IN', 'REALLOCATE_IN', 'PRIORITY_IN', 'RESTORE');

CREATE OR REPLACE VIEW v_preplan_stock_entitlement_beneficiary_balance AS
SELECT lot.stock_reservation_id,
       lot.beneficiary_analysis_id,
       lot.beneficiary_analysis_material_id,
       SUM(lot.remaining_qty)::numeric AS effective_qty
FROM v_preplan_stock_entitlement_lot_balance lot
GROUP BY lot.stock_reservation_id,
         lot.beneficiary_analysis_id,
         lot.beneficiary_analysis_material_id
HAVING SUM(lot.remaining_qty) > 0;

-- Forward-extend V337's latest validator without weakening any legacy branch.
-- All existing consumers (FORMALIZE, MAKE delegation, manual reallocation,
-- RELEASE and RESTORE) must recognize a SUBCONTRACT_HANDOFF_IN positive lot,
-- and every balance calculation / RESTORE counter must recognize the matching
-- OUT.  Replacing the two canonical type-list fragments keeps the complete
-- V337 validation body authoritative instead of duplicating a stale subset.
DO $$
DECLARE
    validator_definition TEXT;
    extended_definition TEXT;
BEGIN
    SELECT pg_get_functiondef(
        'fn_check_preplan_stock_entitlement_event()'::regprocedure)
    INTO validator_definition;
    extended_definition := regexp_replace(
        validator_definition,
        '''MAKE_DELEGATE_OUT'',\s*''REALLOCATE_OUT''',
        '''MAKE_DELEGATE_OUT'', ''SUBCONTRACT_HANDOFF_OUT'', ''REALLOCATE_OUT''',
        'g');
    extended_definition := regexp_replace(
        extended_definition,
        '''MAKE_DELEGATE_IN'',\s*''REALLOCATE_IN''',
        '''MAKE_DELEGATE_IN'', ''SUBCONTRACT_HANDOFF_IN'', ''REALLOCATE_IN''',
        'g');
    IF extended_definition = validator_definition
       OR position('SUBCONTRACT_HANDOFF_OUT' IN extended_definition) = 0
       OR position('SUBCONTRACT_HANDOFF_IN' IN extended_definition) = 0 THEN
        RAISE EXCEPTION
            'V447 could not forward-extend the V337 entitlement validator'
            USING ERRCODE = '23514';
    END IF;
    EXECUTE extended_definition;
END;
$$;

-- V337's forward-extended function continues validating every legacy event,
-- RELEASE/RESTORE and every consumer of the new positive lot. V447 owns only
-- the identity-specific OUT/IN pair.
DROP TRIGGER trg_check_preplan_stock_entitlement_event
    ON preplan_stock_entitlement_events;

CREATE TRIGGER trg_check_preplan_stock_entitlement_event
    BEFORE INSERT ON preplan_stock_entitlement_events
    FOR EACH ROW
    WHEN (NEW.event_type NOT IN (
        'SUBCONTRACT_HANDOFF_OUT', 'SUBCONTRACT_HANDOFF_IN'))
    EXECUTE FUNCTION fn_check_preplan_stock_entitlement_event();

CREATE OR REPLACE FUNCTION fn_check_preplan_subcontract_entitlement_event()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    reservation stock_reservations%ROWTYPE;
    material production_material_analysis_materials%ROWTYPE;
    source_event preplan_stock_entitlement_events%ROWTYPE;
    counter_event preplan_stock_entitlement_events%ROWTYPE;
    slice preplan_subcontract_entitlement_handoff_slices%ROWTYPE;
    item preplan_subcontract_requirement_handoff_items%ROWTYPE;
    remaining NUMERIC(18,4);
    restored NUMERIC(18,4);
BEGIN
    SELECT * INTO reservation
    FROM stock_reservations WHERE id = NEW.stock_reservation_id;
    SELECT * INTO material
    FROM production_material_analysis_materials
    WHERE id = NEW.beneficiary_analysis_material_id;
    IF reservation.id IS NULL
       OR reservation.owner_type <> 'PREPLAN_ANALYSIS'
       OR reservation.purpose <> 'PREPLAN_MATERIAL'
       OR reservation.is_deleted IS DISTINCT FROM FALSE
       OR material.id IS NULL
       OR material.analysis_id <> NEW.beneficiary_analysis_id
       OR material.goods_id <> reservation.goods_id
       OR material.color_id IS DISTINCT FROM reservation.color_id THEN
        RAISE EXCEPTION 'entitlement beneficiary/dimension invalid'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.source_receipt_type IS NOT NULL
       OR NEW.source_receipt_id IS NOT NULL
       OR NEW.source_disposition_event_id IS NOT NULL
       OR NEW.source_stock_document_id IS NOT NULL
       OR NEW.source_stock_document_item_id IS NOT NULL
       OR NEW.target_package_id IS NOT NULL
       OR NEW.target_demand_id IS NOT NULL
       OR NEW.target_stock_reservation_id IS NOT NULL THEN
        RAISE EXCEPTION 'derived handoff entitlement must follow its exact lot'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.source_entitlement_event_id IS NOT NULL THEN
        SELECT * INTO source_event
        FROM preplan_stock_entitlement_events
        WHERE id = NEW.source_entitlement_event_id
        FOR UPDATE;
        SELECT source_event.qty - COALESCE(SUM(used.qty), 0)
        INTO remaining
        FROM preplan_stock_entitlement_events used
        WHERE used.source_entitlement_event_id = source_event.id
          AND used.event_type IN (
              'MAKE_DELEGATE_OUT', 'SUBCONTRACT_HANDOFF_OUT',
              'REALLOCATE_OUT', 'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
        GROUP BY source_event.qty;
        remaining := COALESCE(remaining, source_event.qty);
        IF source_event.id IS NULL
           OR source_event.event_type NOT IN (
                'ORIGIN_IQC', 'ORIGIN_MAKE', 'MAKE_DELEGATE_IN',
                'SUBCONTRACT_HANDOFF_IN', 'REALLOCATE_IN',
                'PRIORITY_IN', 'RESTORE')
           OR source_event.stock_reservation_id <> NEW.stock_reservation_id
           OR source_event.beneficiary_analysis_id
                <> NEW.beneficiary_analysis_id
           OR source_event.beneficiary_analysis_material_id
                <> NEW.beneficiary_analysis_material_id
           OR NEW.qty > remaining THEN
            RAISE EXCEPTION 'event exceeds source entitlement lot'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    IF NEW.counter_event_id IS NOT NULL THEN
        SELECT * INTO counter_event
        FROM preplan_stock_entitlement_events
        WHERE id = NEW.counter_event_id
        FOR UPDATE;
    END IF;

    IF NEW.event_type IN (
            'SUBCONTRACT_HANDOFF_OUT', 'SUBCONTRACT_HANDOFF_IN') THEN
        SELECT * INTO slice
        FROM preplan_subcontract_entitlement_handoff_slices
        WHERE id = NEW.event_group_id;
        SELECT * INTO item
        FROM preplan_subcontract_requirement_handoff_items
        WHERE id = slice.handoff_item_id;
    END IF;

    IF NEW.event_type = 'SUBCONTRACT_HANDOFF_OUT' THEN
        IF slice.id IS NULL
           OR item.id IS NULL
           OR source_event.id IS NULL
           OR NEW.reallocation_id IS NOT NULL
           OR NEW.counter_event_id IS NOT NULL
           OR NEW.source_exact_peg_id IS NOT NULL
           OR NEW.stock_reservation_id
                IS DISTINCT FROM slice.stock_reservation_id
           OR NEW.source_entitlement_event_id
                IS DISTINCT FROM slice.source_entitlement_event_id
           OR NEW.beneficiary_analysis_id
                IS DISTINCT FROM item.source_analysis_id
           OR NEW.beneficiary_analysis_material_id
                IS DISTINCT FROM item.source_analysis_material_id
           OR NEW.qty IS DISTINCT FROM slice.qty THEN
            RAISE EXCEPTION 'invalid SUBCONTRACT_HANDOFF_OUT'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.event_type = 'SUBCONTRACT_HANDOFF_IN' THEN
        IF slice.id IS NULL
           OR item.id IS NULL
           OR NEW.source_entitlement_event_id IS NOT NULL
           OR NEW.reallocation_id IS NOT NULL
           OR counter_event.id IS NULL
           OR counter_event.event_type
                IS DISTINCT FROM 'SUBCONTRACT_HANDOFF_OUT'
           OR counter_event.event_group_id IS DISTINCT FROM slice.id
           OR counter_event.stock_reservation_id
                IS DISTINCT FROM slice.stock_reservation_id
           OR counter_event.qty IS DISTINCT FROM slice.qty
           OR NEW.stock_reservation_id
                IS DISTINCT FROM slice.stock_reservation_id
           OR NEW.beneficiary_analysis_id
                IS DISTINCT FROM item.target_analysis_id
           OR NEW.beneficiary_analysis_material_id
                IS DISTINCT FROM item.target_analysis_material_id
           OR NEW.qty IS DISTINCT FROM slice.qty
           OR NEW.source_exact_peg_id
                IS DISTINCT FROM slice.source_exact_peg_id
           OR NEW.counter_event_id IS DISTINCT FROM counter_event.id THEN
            RAISE EXCEPTION 'invalid SUBCONTRACT_HANDOFF_IN'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.event_type = 'RESTORE' THEN
        SELECT COALESCE(SUM(restored_event.qty), 0)
        INTO restored
        FROM preplan_stock_entitlement_events restored_event
        WHERE restored_event.counter_event_id = NEW.counter_event_id
          AND restored_event.event_type = 'RESTORE';
        IF NEW.source_entitlement_event_id IS NOT NULL
           OR counter_event.id IS NULL
           OR counter_event.event_type NOT IN (
                'MAKE_DELEGATE_OUT', 'SUBCONTRACT_HANDOFF_OUT',
                'REALLOCATE_OUT', 'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
           OR counter_event.stock_reservation_id <> NEW.stock_reservation_id
           OR counter_event.beneficiary_analysis_id
                <> NEW.beneficiary_analysis_id
           OR counter_event.beneficiary_analysis_material_id
                <> NEW.beneficiary_analysis_material_id
           OR NEW.reallocation_id
                IS DISTINCT FROM counter_event.reallocation_id
           OR NEW.qty <> counter_event.qty
           OR restored <> 0
           OR NEW.source_exact_peg_id IS DISTINCT FROM (
                SELECT source_exact_peg_id
                FROM preplan_stock_entitlement_events
                WHERE id = counter_event.source_entitlement_event_id) THEN
            RAISE EXCEPTION 'invalid RESTORE' USING ERRCODE = '23514';
        END IF;
    ELSE
        RAISE EXCEPTION 'unsupported V447 entitlement event'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_preplan_subcontract_entitlement_event
    BEFORE INSERT ON preplan_stock_entitlement_events
    FOR EACH ROW
    WHEN (NEW.event_type IN (
        'SUBCONTRACT_HANDOFF_OUT', 'SUBCONTRACT_HANDOFF_IN'))
    EXECUTE FUNCTION fn_check_preplan_subcontract_entitlement_event();

CREATE OR REPLACE FUNCTION fn_validate_preplan_subcontract_handoff_slice_totals()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    slice_id UUID;
    slice preplan_subcontract_entitlement_handoff_slices%ROWTYPE;
    item preplan_subcontract_requirement_handoff_items%ROWTYPE;
    handoff_state TEXT;
    out_event_id UUID;
    in_event_id UUID;
    out_qty NUMERIC(18,4);
    in_qty NUMERIC(18,4);
    released_qty NUMERIC(18,4);
    restored_qty NUMERIC(18,4);
BEGIN
    IF TG_TABLE_NAME = 'preplan_subcontract_entitlement_handoff_slices' THEN
        slice_id := COALESCE(NEW.id, OLD.id);
    ELSIF COALESCE(NEW.event_type, OLD.event_type) IN (
            'SUBCONTRACT_HANDOFF_OUT', 'SUBCONTRACT_HANDOFF_IN',
            'RELEASE', 'RESTORE') THEN
        slice_id := COALESCE(NEW.event_group_id, OLD.event_group_id);
    ELSE
        RETURN NEW;
    END IF;
    SELECT * INTO slice
    FROM preplan_subcontract_entitlement_handoff_slices
    WHERE id = slice_id;
    IF slice.id IS NULL THEN RETURN NEW; END IF;
    SELECT * INTO item
    FROM preplan_subcontract_requirement_handoff_items
    WHERE id = slice.handoff_item_id;
    SELECT state INTO handoff_state
    FROM v_preplan_subcontract_requirement_handoff_state
    WHERE id = item.handoff_id;

    SELECT id, qty INTO out_event_id, out_qty
    FROM preplan_stock_entitlement_events
    WHERE event_group_id = slice.id
      AND event_type = 'SUBCONTRACT_HANDOFF_OUT';
    SELECT id, qty INTO in_event_id, in_qty
    FROM preplan_stock_entitlement_events
    WHERE event_group_id = slice.id
      AND event_type = 'SUBCONTRACT_HANDOFF_IN'
      AND counter_event_id = out_event_id;
    IF out_event_id IS NULL OR in_event_id IS NULL
       OR out_qty IS DISTINCT FROM slice.qty
       OR in_qty IS DISTINCT FROM slice.qty THEN
        RAISE EXCEPTION
            'subcontract entitlement OUT/IN totals must equal slice quantity'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_subcontract_handoff_pair_total_guard';
    END IF;

    SELECT COALESCE(SUM(event.qty), 0) INTO released_qty
    FROM preplan_stock_entitlement_events event
    WHERE event.event_group_id = slice.id
      AND event.event_type = 'RELEASE'
      AND event.source_entitlement_event_id = in_event_id;
    SELECT COALESCE(SUM(event.qty), 0) INTO restored_qty
    FROM preplan_stock_entitlement_events event
    WHERE event.event_group_id = slice.id
      AND event.event_type = 'RESTORE'
      AND event.counter_event_id = out_event_id;
    IF released_qty IS DISTINCT FROM restored_qty
       OR released_qty NOT IN (0, slice.qty)
       OR (handoff_state = 'ACTIVE' AND released_qty <> 0)
       OR (handoff_state = 'RESTORED' AND released_qty <> slice.qty) THEN
        RAISE EXCEPTION
            'subcontract handoff restore must RELEASE/RESTORE every exact slice in full'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'preplan_subcontract_handoff_restore_total_guard';
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_preplan_subcontract_handoff_slice
    AFTER INSERT ON preplan_subcontract_entitlement_handoff_slices
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_preplan_subcontract_handoff_slice_totals();
CREATE CONSTRAINT TRIGGER trg_validate_preplan_subcontract_handoff_events
    AFTER INSERT ON preplan_stock_entitlement_events
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION
        fn_validate_preplan_subcontract_handoff_slice_totals();

CREATE VIEW v_preplan_subcontract_entitlement_handoff_slice_state AS
SELECT slice.*,
       item.handoff_id,
       outgoing.id AS out_event_id,
       incoming.id AS in_event_id,
       COALESCE(restored.restored_qty, 0)::numeric AS restored_qty,
       CASE WHEN COALESCE(restored.restored_qty, 0) = slice.qty
            THEN 'RESTORED' ELSE 'ACTIVE' END AS state
FROM preplan_subcontract_entitlement_handoff_slices slice
JOIN preplan_subcontract_requirement_handoff_items item
  ON item.id = slice.handoff_item_id
JOIN preplan_stock_entitlement_events outgoing
  ON outgoing.event_group_id = slice.id
 AND outgoing.event_type = 'SUBCONTRACT_HANDOFF_OUT'
JOIN preplan_stock_entitlement_events incoming
  ON incoming.event_group_id = slice.id
 AND incoming.event_type = 'SUBCONTRACT_HANDOFF_IN'
 AND incoming.counter_event_id = outgoing.id
LEFT JOIN LATERAL (
    SELECT SUM(event.qty)::numeric AS restored_qty
    FROM preplan_stock_entitlement_events event
    WHERE event.event_group_id = slice.id
      AND event.event_type = 'RESTORE'
      AND event.counter_event_id = outgoing.id
) restored ON TRUE;

-- Mapped material identity is historical evidence.  A refresh may change
-- availability/shortage projections, but it may not rewrite the BOM edge,
-- relative path or goods/color/unit UUID of either endpoint.
CREATE OR REPLACE FUNCTION fn_guard_preplan_subcontract_handoff_material_identity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM preplan_subcontract_requirement_handoff_items item
        WHERE item.source_analysis_material_id = OLD.id
           OR item.target_analysis_material_id = OLD.id
    ) AND (
        NEW.analysis_id IS DISTINCT FROM OLD.analysis_id
        OR NEW.analysis_item_id IS DISTINCT FROM OLD.analysis_item_id
        OR NEW.node_key IS DISTINCT FROM OLD.node_key
        OR NEW.parent_node_key IS DISTINCT FROM OLD.parent_node_key
        OR NEW.bom_item_id IS DISTINCT FROM OLD.bom_item_id
        OR NEW.goods_id IS DISTINCT FROM OLD.goods_id
        OR NEW.color_id IS DISTINCT FROM OLD.color_id
        OR NEW.unit_id IS DISTINCT FROM OLD.unit_id
    ) THEN
        RAISE EXCEPTION
            'material identity referenced by a subcontract handoff is immutable'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_preplan_subcontract_handoff_material_identity
    BEFORE UPDATE OF analysis_id, analysis_item_id, node_key, parent_node_key,
        bom_item_id, goods_id, color_id, unit_id
    ON production_material_analysis_materials
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_preplan_subcontract_handoff_material_identity();

-- An active future claim is a contractual ownership promise, not V309's
-- discretionary priority.  Cancelling/repointing its source action/allocation
-- would strand the target analysis, so such mutations fail closed until the
-- parent-output handoff has been fully RESTORED.
CREATE OR REPLACE FUNCTION fn_guard_preplan_subcontract_claimed_supply_history()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM preplan_subcontract_requirement_supply_claims claim
        JOIN preplan_subcontract_requirement_handoff_items item
          ON item.id = claim.handoff_item_id
        JOIN v_preplan_subcontract_requirement_handoff_state state
          ON state.id = item.handoff_id
         AND state.state = 'ACTIVE'
        WHERE (TG_TABLE_NAME = 'preplan_supply_actions'
               AND claim.source_supply_action_id = OLD.id)
           OR (TG_TABLE_NAME = 'preplan_supply_action_allocations'
               AND claim.source_supply_action_allocation_id = OLD.id)
    ) THEN
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION
                'active subcontract handoff future supply claim is immutable until RESTORE'
                USING ERRCODE = '55000';
        ELSIF TG_TABLE_NAME = 'preplan_supply_actions' THEN
            IF NEW.analysis_id IS DISTINCT FROM OLD.analysis_id
               OR NEW.route IS DISTINCT FROM OLD.route
               OR NEW.requested_qty IS DISTINCT FROM OLD.requested_qty
               OR NEW.status = 'CANCELLED' AND OLD.status <> 'CANCELLED'
               OR NEW.external_document_type
                    IS DISTINCT FROM OLD.external_document_type
               OR NEW.external_document_id
                    IS DISTINCT FROM OLD.external_document_id THEN
                RAISE EXCEPTION
                    'active subcontract handoff future supply claim is immutable until RESTORE'
                    USING ERRCODE = '55000';
            END IF;
        ELSIF TG_TABLE_NAME = 'preplan_supply_action_allocations' THEN
            IF NEW.analysis_id IS DISTINCT FROM OLD.analysis_id
               OR NEW.action_id IS DISTINCT FROM OLD.action_id
               OR NEW.analysis_material_id
                    IS DISTINCT FROM OLD.analysis_material_id
               OR NEW.allocated_qty IS DISTINCT FROM OLD.allocated_qty
               OR NEW.external_item_id IS DISTINCT FROM OLD.external_item_id THEN
                RAISE EXCEPTION
                    'active subcontract handoff future supply claim is immutable until RESTORE'
                    USING ERRCODE = '55000';
            END IF;
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_preplan_subcontract_claimed_action
    BEFORE UPDATE OR DELETE ON preplan_supply_actions
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_preplan_subcontract_claimed_supply_history();
CREATE TRIGGER trg_guard_preplan_subcontract_claimed_allocation
    BEFORE UPDATE OR DELETE ON preplan_supply_action_allocations
    FOR EACH ROW EXECUTE FUNCTION
        fn_guard_preplan_subcontract_claimed_supply_history();

COMMENT ON TABLE preplan_subcontract_requirement_handoffs IS
    'V447 append-only cross-analysis subcontract-preparation requirement ownership header';
COMMENT ON TABLE preplan_subcontract_requirement_handoff_items IS
    'Exact source/target material mapping by relative BOM UUID path and goods/color/unit UUID';
COMMENT ON TABLE preplan_subcontract_requirement_supply_claims IS
    'Future exact source allocation capacity promised to the preparation material line; active capacity is derived from TAKEOVER/RESTORE';
COMMENT ON TABLE preplan_subcontract_entitlement_handoff_slices IS
    'Immutable exact-lot slice moved by SUBCONTRACT_HANDOFF_OUT/IN without changing physical reservation or exact origin';
COMMENT ON TABLE preplan_subcontract_requirement_handoff_events IS
    'Append-only parent-output TAKEOVER/RESTORE events; source parent demand remains, only its recursive internal-child ownership moves';
COMMENT ON VIEW v_preplan_subcontract_parent_output_claim_balance IS
    'Active parent-output quantity that MaterialAnalysisService subtracts before expanding SUBCONTRACT descendants';
COMMENT ON VIEW v_preplan_subcontract_target_future_supply IS
    'Not-yet-arrived claimed source allocation capacity projected as target preparation future supply';
