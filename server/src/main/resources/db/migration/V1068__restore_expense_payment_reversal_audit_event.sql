-- V999_11 introduced the actual financial-application payment reversal event.
-- V1000 and V1002 subsequently rebuilt this check for staged approval and
-- abandonment, omitting that still-produced event. Keep the complete union;
-- this changes no historical event or claim and permits no unknown event kind.
ALTER TABLE expense_claim_events DROP CONSTRAINT expense_claim_events_type_chk;
ALTER TABLE expense_claim_events ADD CONSTRAINT expense_claim_events_type_chk
    CHECK (event_type IN (
        'CREATED', 'SUBMITTED', 'WITHDRAWN', 'EDITED', 'STAGE_APPROVED',
        'APPROVED', 'REJECTED', 'PAID', 'ABANDONED', 'PAYMENT_REVERSED'));
