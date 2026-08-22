-- V371: a reversed fulfillment preserves history but must not block a later
-- replacement attempt for the same resolution. Only one active allocation.

ALTER TABLE subcontract_loss_fulfillment_allocations
    DROP CONSTRAINT subcontract_loss_fulfillment_resolution_uk;
CREATE UNIQUE INDEX ux_subcontract_loss_fulfillment_active_resolution
    ON subcontract_loss_fulfillment_allocations(resolution_id)
    WHERE status='APPLIED';
