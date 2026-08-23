-- V370: compensation fulfillment has its own reversible lifecycle. Physical
-- source documents reverse first; supplier-site material replacement reverses
-- by decrementing compensated_qty under the same conservation guard.

ALTER TABLE subcontract_loss_fulfillment_allocations
    ADD COLUMN status TEXT NOT NULL DEFAULT 'APPLIED'
        CHECK(status IN ('APPLIED','REVERSED')),
    ADD COLUMN row_version BIGINT NOT NULL DEFAULT 0 CHECK(row_version>=0),
    ADD COLUMN reversed_by UUID REFERENCES users(id) ON DELETE SET NULL,
    ADD COLUMN reversed_at TIMESTAMPTZ,
    ADD COLUMN reverse_reason TEXT,
    ADD CONSTRAINT subcontract_loss_fulfillment_reverse_shape_chk CHECK(
        (status='APPLIED' AND reversed_at IS NULL AND reversed_by IS NULL)
        OR (status='REVERSED' AND reversed_at IS NOT NULL AND reverse_reason IS NOT NULL));

CREATE INDEX idx_subcontract_loss_fulfillment_active_resolution
    ON subcontract_loss_fulfillment_allocations(resolution_id,status);
