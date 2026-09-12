-- Freeze the complete normalized IQC batch request on its existing PASS/FAIL
-- events. Their IDs, quantities, costs and source references stay unchanged.
-- Historical requests cannot be reconstructed from timestamps; keep NULL.
ALTER TABLE procurement_inspection_events
    ADD COLUMN batch_request_hash TEXT,
    ADD CONSTRAINT procurement_inspection_events_batch_hash_chk
        CHECK (batch_request_hash IS NULL OR batch_request_hash ~ '^[0-9a-f]{64}$');

COMMENT ON COLUMN procurement_inspection_events.batch_request_hash IS
    'SHA-256 of the normalized complete IQC batch request; NULL for single decisions and unmodified historical events. The existing ALWAYS append-only guard protects this field too.';
