-- V999.11 already admitted the real payment-reversal history event emitted by
-- ExpenseClaimService and understood by existing clients. V1000/V1002 extended
-- the event catalogue for stage review/abandonment but inadvertently lost it.
-- Restore only that existing event, retaining every current type and rejecting
-- arbitrary event names. No historical rows, permissions or money are changed.
DO $expense_event_contract$
DECLARE current_types text[];
BEGIN
    SELECT array_agg(value[1] ORDER BY value[1]) INTO current_types
    FROM pg_constraint definition
    CROSS JOIN LATERAL regexp_matches(pg_get_constraintdef(definition.oid),'''([A-Z_]+)''','g') value
    WHERE definition.conrelid='expense_claim_events'::regclass
      AND definition.conname='expense_claim_events_type_chk';
    IF current_types IS DISTINCT FROM ARRAY[
        'ABANDONED','APPROVED','CREATED','EDITED','PAID','REJECTED',
        'STAGE_APPROVED','SUBMITTED','WITHDRAWN']::text[] THEN
        RAISE EXCEPTION 'V1062 expense claim event catalogue changed; preserve and review its exact contract';
    END IF;
    ALTER TABLE expense_claim_events DROP CONSTRAINT expense_claim_events_type_chk;
    ALTER TABLE expense_claim_events ADD CONSTRAINT expense_claim_events_type_chk CHECK(event_type IN(
        'CREATED','SUBMITTED','WITHDRAWN','EDITED','STAGE_APPROVED','APPROVED','REJECTED','PAID','ABANDONED','PAYMENT_REVERSED'));
END $expense_event_contract$;
