-- V1000/V1002 correctly added native-stage and abandonment events but replaced
-- the CHECK without the earlier finance-owned payment-reversal event.
-- Preserve the complete current vocabulary and append only that missing fact.
-- Existing events, permissions, source guards and immutable history are unchanged.
ALTER TABLE expense_claim_events DROP CONSTRAINT expense_claim_events_type_chk;
ALTER TABLE expense_claim_events ADD CONSTRAINT expense_claim_events_type_chk
 CHECK(event_type IN('CREATED','SUBMITTED','WITHDRAWN','EDITED','STAGE_APPROVED',
     'APPROVED','REJECTED','PAID','ABANDONED','PAYMENT_REVERSED'));
