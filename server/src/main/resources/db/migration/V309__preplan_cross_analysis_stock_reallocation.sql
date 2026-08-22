-- V309: cross-analysis pre-plan stock reallocation and replenishment priority.
--
-- Business wording is deliberately "reallocation / priority replenishment", not
-- debt or repayment.  A qualified lot may be explicitly reallocated from one
-- material-analysis node to another; the source node keeps an auditable priority
-- for the next eligible supply.  stock_reservations remains the only physical
-- reservation truth.  This migration adds an append-only entitlement event ledger
-- that says which exact analysis node currently benefits from each physical lot.
--
-- V307 exact pegs remain immutable origin evidence.  Historical V298 reservations
-- without a V307 exact peg are intentionally not guessed or backfilled.

-- ========================= V307 MAKE exact provenance =========================

ALTER TABLE preplan_analysis_stock_exact_pegs
    ALTER COLUMN source_disposition_event_id DROP NOT NULL,
    DROP CONSTRAINT preplan_exact_peg_receipt_type_chk,
    ADD COLUMN source_stock_document_id UUID
        REFERENCES stock_documents(id) ON DELETE RESTRICT,
    ADD COLUMN source_stock_document_item_id UUID
        REFERENCES stock_document_items(id) ON DELETE RESTRICT,
    ADD CONSTRAINT preplan_exact_peg_source_type_chk
        CHECK (source_receipt_type IN ('PURCHASE', 'SUBCONTRACT', 'MAKE')),
    ADD CONSTRAINT preplan_exact_peg_source_shape_chk CHECK (
        (
            source_receipt_type IN ('PURCHASE', 'SUBCONTRACT')
            AND source_disposition_event_id IS NOT NULL
            AND source_stock_document_id IS NULL
            AND source_stock_document_item_id IS NULL
        )
        OR
        (
            source_receipt_type = 'MAKE'
            AND source_disposition_event_id IS NULL
            AND source_stock_document_id IS NOT NULL
            AND source_receipt_id = source_stock_document_id
            AND source_stock_document_item_id IS NOT NULL
        )
    );

CREATE INDEX idx_preplan_exact_peg_finished_in
    ON preplan_analysis_stock_exact_pegs(
        source_stock_document_id, source_stock_document_item_id)
    WHERE source_receipt_type = 'MAKE';

-- =========================== reallocation header =============================

CREATE TABLE preplan_material_reallocations (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    from_analysis_id                UUID NOT NULL,
    from_analysis_material_id       UUID NOT NULL,
    to_analysis_id                  UUID NOT NULL,
    to_analysis_material_id         UUID NOT NULL,
    warehouse_id                    UUID NOT NULL
        REFERENCES warehouses(id) ON DELETE RESTRICT,
    goods_id                        UUID NOT NULL
        REFERENCES goods(id) ON DELETE RESTRICT,
    color_id                        UUID
        REFERENCES colors(id) ON DELETE RESTRICT,
    unit_id                         UUID NOT NULL
        REFERENCES units(id) ON DELETE RESTRICT,
    qty                             NUMERIC(18,4) NOT NULL,
    priority_fulfilled_qty          NUMERIC(18,4) NOT NULL DEFAULT 0,
    status                          TEXT NOT NULL DEFAULT 'OPEN',
    reason                          TEXT NOT NULL,
    idempotency_key                 TEXT NOT NULL,
    request_hash                    TEXT NOT NULL,
    source_version                  BIGINT NOT NULL,
    source_fingerprint              TEXT NOT NULL,
    target_version                  BIGINT NOT NULL,
    target_fingerprint              TEXT NOT NULL,
    lock_version                    BIGINT NOT NULL DEFAULT 0,
    created_by                      UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                      UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    closed_by                       UUID REFERENCES users(id) ON DELETE RESTRICT,
    closed_at                       TIMESTAMPTZ,
    close_reason                    TEXT,
    CONSTRAINT preplan_reallocation_from_material_fk
        FOREIGN KEY (from_analysis_id, from_analysis_material_id)
        REFERENCES production_material_analysis_materials(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_reallocation_to_material_fk
        FOREIGN KEY (to_analysis_id, to_analysis_material_id)
        REFERENCES production_material_analysis_materials(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_reallocation_distinct_chk CHECK (
        from_analysis_id <> to_analysis_id
        AND from_analysis_material_id <> to_analysis_material_id),
    CONSTRAINT preplan_reallocation_qty_chk CHECK (
        qty > 0
        AND priority_fulfilled_qty >= 0
        AND priority_fulfilled_qty <= qty),
    CONSTRAINT preplan_reallocation_status_chk CHECK (
        status IN ('OPEN', 'PARTIAL', 'FULFILLED', 'REVERSED', 'CANCELLED')),
    CONSTRAINT preplan_reallocation_status_qty_chk CHECK (
        (status = 'OPEN' AND priority_fulfilled_qty = 0)
        OR (status = 'PARTIAL'
            AND priority_fulfilled_qty > 0
            AND priority_fulfilled_qty < qty)
        OR (status = 'FULFILLED' AND priority_fulfilled_qty = qty)
        OR (status = 'REVERSED' AND priority_fulfilled_qty = 0)
        OR status = 'CANCELLED'),
    CONSTRAINT preplan_reallocation_reason_chk CHECK (
        reason = btrim(reason) AND length(reason) BETWEEN 2 AND 1000),
    CONSTRAINT preplan_reallocation_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 160),
    CONSTRAINT preplan_reallocation_hash_chk CHECK (
        request_hash ~ '^[0-9a-f]{64}$'
        AND source_fingerprint ~ '^[0-9a-f]{64}$'
        AND target_fingerprint ~ '^[0-9a-f]{64}$'),
    CONSTRAINT preplan_reallocation_version_chk CHECK (
        source_version >= 0 AND target_version >= 0 AND lock_version >= 0),
    CONSTRAINT preplan_reallocation_close_chk CHECK (
        (
            status NOT IN ('REVERSED', 'CANCELLED')
            AND closed_by IS NULL AND closed_at IS NULL AND close_reason IS NULL
        )
        OR
        (
            status IN ('REVERSED', 'CANCELLED')
            AND closed_by IS NOT NULL AND closed_at IS NOT NULL
            AND close_reason IS NOT NULL
            AND close_reason = btrim(close_reason)
            AND length(close_reason) BETWEEN 2 AND 1000
        )
    ),
    CONSTRAINT uq_preplan_reallocation_idempotency
        UNIQUE (created_by, idempotency_key)
);

CREATE INDEX idx_preplan_reallocation_from_open
    ON preplan_material_reallocations(
        from_analysis_id, from_analysis_material_id, created_at, id)
    WHERE status IN ('OPEN', 'PARTIAL');

CREATE INDEX idx_preplan_reallocation_to_open
    ON preplan_material_reallocations(
        to_analysis_id, to_analysis_material_id, created_at, id)
    WHERE status IN ('OPEN', 'PARTIAL');

CREATE INDEX idx_preplan_reallocation_priority_dimension
    ON preplan_material_reallocations(
        warehouse_id, goods_id, color_id, status, created_at, id)
    WHERE status IN ('OPEN', 'PARTIAL');

-- ======================= append-only entitlement events ======================

CREATE TABLE preplan_stock_entitlement_events (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_group_id                  UUID NOT NULL,
    stock_reservation_id            UUID NOT NULL
        REFERENCES stock_reservations(id) ON DELETE RESTRICT,
    beneficiary_analysis_id         UUID NOT NULL,
    beneficiary_analysis_material_id UUID NOT NULL,
    event_type                      TEXT NOT NULL,
    qty                             NUMERIC(18,4) NOT NULL,
    source_entitlement_event_id     UUID
        REFERENCES preplan_stock_entitlement_events(id) ON DELETE RESTRICT,
    reallocation_id                 UUID
        REFERENCES preplan_material_reallocations(id) ON DELETE RESTRICT,
    source_exact_peg_id             UUID
        REFERENCES preplan_analysis_stock_exact_pegs(id) ON DELETE RESTRICT,
    source_receipt_type             TEXT,
    source_receipt_id               UUID,
    source_disposition_event_id     UUID
        REFERENCES procurement_inspection_events(id) ON DELETE RESTRICT,
    source_stock_document_id        UUID
        REFERENCES stock_documents(id) ON DELETE RESTRICT,
    source_stock_document_item_id   UUID
        REFERENCES stock_document_items(id) ON DELETE RESTRICT,
    target_package_id               UUID
        REFERENCES production_planning_packages(id) ON DELETE RESTRICT,
    target_demand_id                UUID
        REFERENCES production_material_demands(id) ON DELETE RESTRICT,
    target_stock_reservation_id     UUID
        REFERENCES stock_reservations(id) ON DELETE RESTRICT,
    counter_event_id                UUID
        REFERENCES preplan_stock_entitlement_events(id) ON DELETE RESTRICT,
    idempotency_key                 TEXT NOT NULL,
    created_by                      UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT preplan_entitlement_event_beneficiary_fk
        FOREIGN KEY (beneficiary_analysis_id, beneficiary_analysis_material_id)
        REFERENCES production_material_analysis_materials(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT preplan_entitlement_event_type_chk CHECK (event_type IN (
        'ORIGIN_IQC', 'ORIGIN_MAKE',
        'REALLOCATE_IN', 'REALLOCATE_OUT',
        'PRIORITY_IN', 'PRIORITY_OUT',
        'PRIORITY_SATISFIED_IN_PLACE',
        'FORMALIZE', 'RESTORE', 'RELEASE')),
    CONSTRAINT preplan_entitlement_event_qty_chk CHECK (qty > 0),
    CONSTRAINT preplan_entitlement_event_key_chk CHECK (
        idempotency_key = btrim(idempotency_key)
        AND length(idempotency_key) BETWEEN 8 AND 200),
    CONSTRAINT preplan_entitlement_event_key_uk UNIQUE (idempotency_key),
    CONSTRAINT preplan_entitlement_event_no_self_ref_chk CHECK (
        source_entitlement_event_id IS DISTINCT FROM id
        AND counter_event_id IS DISTINCT FROM id)
);

CREATE INDEX idx_preplan_entitlement_reservation
    ON preplan_stock_entitlement_events(
        stock_reservation_id, created_at, id);

CREATE INDEX idx_preplan_entitlement_beneficiary
    ON preplan_stock_entitlement_events(
        beneficiary_analysis_id, beneficiary_analysis_material_id,
        stock_reservation_id, created_at, id);

CREATE INDEX idx_preplan_entitlement_source_lot
    ON preplan_stock_entitlement_events(
        source_entitlement_event_id, created_at, id)
    WHERE source_entitlement_event_id IS NOT NULL;

CREATE INDEX idx_preplan_entitlement_reallocation
    ON preplan_stock_entitlement_events(
        reallocation_id, event_type, created_at, id)
    WHERE reallocation_id IS NOT NULL;

CREATE UNIQUE INDEX uq_preplan_entitlement_counter_once
    ON preplan_stock_entitlement_events(counter_event_id)
    WHERE counter_event_id IS NOT NULL
      AND event_type IN ('REALLOCATE_IN', 'PRIORITY_IN');

-- Positive events are entitlement lots.  Every negative event consumes exactly
-- one positive source lot.  Neutral priority evidence does not change balance.
CREATE VIEW v_preplan_stock_entitlement_lot_balance AS
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
          'REALLOCATE_OUT', 'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
) consumed ON TRUE
WHERE positive.event_type IN (
    'ORIGIN_IQC', 'ORIGIN_MAKE', 'REALLOCATE_IN', 'PRIORITY_IN', 'RESTORE');

CREATE VIEW v_preplan_stock_entitlement_beneficiary_balance AS
SELECT lot.stock_reservation_id,
       lot.beneficiary_analysis_id,
       lot.beneficiary_analysis_material_id,
       SUM(lot.remaining_qty)::numeric AS effective_qty
FROM v_preplan_stock_entitlement_lot_balance lot
GROUP BY lot.stock_reservation_id,
         lot.beneficiary_analysis_id,
         lot.beneficiary_analysis_material_id
HAVING SUM(lot.remaining_qty) > 0;

COMMENT ON TABLE preplan_material_reallocations IS
    '跨物料分析显式让料及来源计划后续合格供给优先补齐；不是债务或还款台账';
COMMENT ON TABLE preplan_stock_entitlement_events IS
    '不可改删的计划前库存权益事件账；stock_reservations 保持唯一物理预留真相';
COMMENT ON VIEW v_preplan_stock_entitlement_lot_balance IS
    '每个正向 entitlement lot 的已用量与剩余量；负事件只能消耗一个正 lot';
COMMENT ON VIEW v_preplan_stock_entitlement_beneficiary_balance IS
    '按物理 reservation 与当前受益分析物料行汇总的有效权益';

