-- V367: an operationally entered deduction is only a suggestion. Accepted
-- claim value is written exclusively by the finance decision transaction.

ALTER TABLE subcontract_loss_cases
    ADD COLUMN suggested_claim_amount_local NUMERIC(18,4) NOT NULL DEFAULT 0
        CHECK (suggested_claim_amount_local>=0);

COMMENT ON COLUMN subcontract_loss_cases.suggested_claim_amount_local IS
    'Operational suggestion copied from legacy deduct_amount; never AP or accepted claim authority';
COMMENT ON COLUMN subcontract_loss_cases.claim_amount_local IS
    'Finance-accepted monetary resolutions only; zero until a responsibility decision';
