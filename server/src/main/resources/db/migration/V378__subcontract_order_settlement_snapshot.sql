-- V378: subcontract finance approval must freeze the contractual settlement
-- method on the order. Historical rows remain nullable and require explicit
-- reconciliation before a new receipt may use them.

ALTER TABLE subcontract_orders
    ADD COLUMN settlement_method_id UUID;

ALTER TABLE subcontract_orders
    ADD CONSTRAINT fk_subcontract_orders_settlement_method
    FOREIGN KEY(settlement_method_id) REFERENCES settlement_methods(id)
    ON DELETE RESTRICT NOT VALID;
ALTER TABLE subcontract_orders
    VALIDATE CONSTRAINT fk_subcontract_orders_settlement_method;

CREATE INDEX idx_subcontract_orders_settlement_method
    ON subcontract_orders(settlement_method_id)
    WHERE settlement_method_id IS NOT NULL;

-- Enforced for all new/updated rows without pretending historical approved
-- orders already have a reviewed settlement snapshot.
ALTER TABLE subcontract_orders
    ADD CONSTRAINT subcontract_orders_approved_settlement_chk
    CHECK(status<>1 OR settlement_method_id IS NOT NULL) NOT VALID;

COMMENT ON COLUMN subcontract_orders.settlement_method_id IS
    'Finance-approved contractual settlement method snapshot; historical NULL must be reconciled, never guessed from current supplier defaults';
