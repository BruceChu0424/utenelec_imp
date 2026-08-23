-- V366: a waste document may contain kg, pieces and metres. Header quantities
-- must never add heterogeneous units; mixed cases keep quantities on lines.

ALTER TABLE subcontract_loss_cases
    ALTER COLUMN actual_loss_qty DROP NOT NULL,
    ALTER COLUMN allowed_loss_qty DROP NOT NULL,
    ALTER COLUMN excess_loss_qty DROP NOT NULL,
    ADD COLUMN quantity_unit_id UUID REFERENCES units(id) ON DELETE RESTRICT,
    ADD COLUMN quantity_summary_kind TEXT NOT NULL DEFAULT 'SAME_UNIT'
        CHECK (quantity_summary_kind IN ('SAME_UNIT','MIXED_UNITS'));

ALTER TABLE subcontract_loss_cases
    DROP CONSTRAINT subcontract_loss_cases_qty_identity_chk;
ALTER TABLE subcontract_loss_cases
    ADD CONSTRAINT subcontract_loss_cases_qty_summary_shape_chk CHECK (
        (quantity_summary_kind='SAME_UNIT'
            AND actual_loss_qty IS NOT NULL
            AND allowed_loss_qty IS NOT NULL
            AND excess_loss_qty IS NOT NULL
            AND actual_loss_qty=allowed_loss_qty+excess_loss_qty)
        OR (quantity_summary_kind='MIXED_UNITS'
            AND actual_loss_qty IS NULL
            AND allowed_loss_qty IS NULL
            AND excess_loss_qty IS NULL
            AND quantity_unit_id IS NULL));

COMMENT ON COLUMN subcontract_loss_cases.quantity_summary_kind IS
    'SAME_UNIT permits header quantity totals; MIXED_UNITS requires line-level quantities only';
