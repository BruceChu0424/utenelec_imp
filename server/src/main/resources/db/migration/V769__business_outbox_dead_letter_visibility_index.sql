-- Failed business events remain actionable after automatic retries stop.
-- Keep the status=2 count bounded by unresolved events rather than scanning
-- years of successfully processed payloads. This does not replay/delete data.
CREATE INDEX idx_business_outbox_dead_letter
    ON business_outbox(id) WHERE status = 2;
