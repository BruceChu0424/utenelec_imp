-- V332: explicit, dated application of supplier credits, accepted claims and
-- prepayments to positive AP. Current cumulative offsets on ar_ap_ledger are a
-- cache; this reversible allocation ledger is the historical as-of authority.

CREATE TABLE supplier_open_item_offsets (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id                     UUID NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
    currency_id                     UUID NOT NULL REFERENCES currencies(id) ON DELETE RESTRICT,
    source_ledger_id                UUID NOT NULL REFERENCES ar_ap_ledger(id) ON DELETE RESTRICT,
    target_ledger_id                UUID NOT NULL REFERENCES ar_ap_ledger(id) ON DELETE RESTRICT,
    resolution_id                   UUID REFERENCES subcontract_loss_resolutions(id) ON DELETE RESTRICT,
    amount_original                 NUMERIC(18,4) NOT NULL CHECK (amount_original > 0),
    source_amount_local             NUMERIC(18,4) NOT NULL CHECK (source_amount_local > 0),
    target_amount_local             NUMERIC(18,4) NOT NULL CHECK (target_amount_local > 0),
    source_balance_before_original  NUMERIC(18,4) NOT NULL,
    source_balance_after_original   NUMERIC(18,4) NOT NULL,
    target_balance_before_original  NUMERIC(18,4) NOT NULL,
    target_balance_after_original   NUMERIC(18,4) NOT NULL,
    effective_date                  DATE NOT NULL,
    status                          TEXT NOT NULL DEFAULT 'APPLIED'
        CHECK (status IN ('APPLIED', 'REVERSED')),
    reason                          TEXT NOT NULL,
    row_version                     BIGINT NOT NULL DEFAULT 0 CHECK (row_version >= 0),
    applied_by                      UUID REFERENCES users(id) ON DELETE SET NULL,
    reversed_by                     UUID REFERENCES users(id) ON DELETE SET NULL,
    reversed_at                     TIMESTAMPTZ,
    reverse_reason                  TEXT,
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                      UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by                      UUID REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT supplier_open_item_offsets_distinct_chk CHECK (
        source_ledger_id <> target_ledger_id),
    CONSTRAINT supplier_open_item_offsets_source_snapshot_chk CHECK (
        source_balance_before_original <= 0
        AND source_balance_after_original <= 0
        AND source_balance_after_original =
            source_balance_before_original + amount_original),
    CONSTRAINT supplier_open_item_offsets_target_snapshot_chk CHECK (
        target_balance_before_original >= 0
        AND target_balance_after_original >= 0
        AND target_balance_after_original =
            target_balance_before_original - amount_original),
    CONSTRAINT supplier_open_item_offsets_reverse_shape_chk CHECK (
        (status = 'APPLIED' AND reversed_at IS NULL AND reversed_by IS NULL)
        OR (status = 'REVERSED' AND reversed_at IS NOT NULL AND reverse_reason IS NOT NULL))
);

CREATE INDEX idx_supplier_open_item_offsets_target_date
    ON supplier_open_item_offsets(target_ledger_id, effective_date, id)
    WHERE status = 'APPLIED';
CREATE INDEX idx_supplier_open_item_offsets_source_date
    ON supplier_open_item_offsets(source_ledger_id, effective_date, id)
    WHERE status = 'APPLIED';
CREATE INDEX idx_supplier_open_item_offsets_supplier_date
    ON supplier_open_item_offsets(supplier_id, effective_date, id);

COMMENT ON TABLE supplier_open_item_offsets IS
    'Dated reversible application of supplier credits, accepted claims or prepayments to positive AP; no silent netting';
