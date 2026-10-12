-- Review edits preserve the original attempt and its immutable commercial and
-- display snapshots. A new PENDING attempt records the recalculated document.
ALTER TABLE procurement_order_approval_events
    DROP CONSTRAINT procurement_order_approval_events_event_type_check;
ALTER TABLE procurement_order_approval_events
    ADD CONSTRAINT procurement_order_approval_events_event_type_check
    CHECK (event_type IN ('SUBMITTED','APPROVED','REJECTED','CANCELED','REASSIGNED','FINANCE_EDIT'));

COMMENT ON COLUMN procurement_order_approval_cases.submission_snapshot IS
    'Immutable facts of one review attempt; finance edits cancel it and create the next attempt, preserving original identity and history';
