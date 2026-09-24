-- Preserve submitted facts across rejection/withdrawal edits. Existing editable
-- rows cannot prove their previous submitted values, so never fabricate backfills.
ALTER TABLE expense_claims
    ADD COLUMN submission_snapshot JSONB,
    ADD COLUMN previous_submission_snapshot JSONB,
    ADD COLUMN resubmission BOOLEAN NOT NULL DEFAULT FALSE,
    ADD CONSTRAINT expense_claim_submission_snapshot_object
        CHECK (submission_snapshot IS NULL OR jsonb_typeof(submission_snapshot) = 'object'),
    ADD CONSTRAINT expense_claim_previous_submission_snapshot_object
        CHECK (previous_submission_snapshot IS NULL OR jsonb_typeof(previous_submission_snapshot) = 'object');

-- Business submission events prove repetition, but do not contain the old rows.
UPDATE expense_claims claim
SET resubmission = TRUE
WHERE (SELECT count(*) FROM expense_claim_events event
       WHERE event.claim_id = claim.id AND event.event_type = 'SUBMITTED') > 1;
