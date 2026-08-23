-- IQC PASS is a positive release decision: an extra release note is optional.
-- FAIL remains fail-closed and must preserve a non-blank quality reason.
-- V222 is already applied and immutable, so this is a forward-only constraint change.

ALTER TABLE procurement_inspection_events
    DROP CONSTRAINT procurement_inspection_events_reason_chk;

ALTER TABLE procurement_inspection_events
    ADD CONSTRAINT procurement_inspection_events_reason_chk CHECK (
        action IN ('RECEIVED', 'PASS', 'PRODUCTION_WOKEN', 'RECEIPT_REVERSED')
        OR NULLIF(btrim(reason), '') IS NOT NULL
    ) NOT VALID;

ALTER TABLE procurement_inspection_events
    VALIDATE CONSTRAINT procurement_inspection_events_reason_chk;
